"""
Test script for Azure AI Foundry Agent with SQL MCP Server.

This script creates an AI agent that connects to a SQL MCP Server (powered by
Data API Builder) and answers questions about an e-commerce database containing
Categories, Products, Customers, Orders, and OrderItems.

Prerequisites:
    1. Azure AI Foundry project with a GPT-4o deployment
    2. SQL MCP Server running (locally via `dab start` or on Azure Container Apps)
    3. `az login` completed for Azure AD authentication
    4. .env file configured (copy from .env.template)

Usage:
    pip install -r requirements.txt
    python test_agent.py
"""

import os
import sys
import time

from dotenv import load_dotenv
from azure.identity import DefaultAzureCredential
from azure.ai.projects import AIProjectClient
from azure.ai.agents.models import (
    ListSortOrder,
    McpTool,
    RequiredMcpToolCall,
    SubmitToolApprovalAction,
    ToolApproval,
)

load_dotenv()

PROJECT_ENDPOINT = os.environ.get("PROJECT_ENDPOINT", "")
MODEL_DEPLOYMENT_NAME = os.environ.get("MODEL_DEPLOYMENT_NAME", "gpt-5")
MCP_SERVER_URL = os.environ.get("MCP_SERVER_URL", "https://sql-mcp-dab.reddune-fdb4aafa.northeurope.azurecontainerapps.io/mcp")

# Test queries to run against the agent
TEST_QUERIES = [
    "What entities are available? Describe each one briefly.",
    "List the top 5 most expensive products with their category name.",
    "How many orders does each customer have? Show customer name and order count.",
    "What is the total revenue by product category?",
    "Show the details of order #4 including all its line items and product names.",
]


def validate_config():
    """Validate that required configuration is present."""
    if not PROJECT_ENDPOINT:
        print("ERROR: PROJECT_ENDPOINT not set in .env file.")
        print("Get it from https://ai.azure.com → your project → Overview")
        sys.exit(1)
    if not MODEL_DEPLOYMENT_NAME:
        print("ERROR: MODEL_DEPLOYMENT_NAME not set in .env file.")
        sys.exit(1)
    print(f"Project endpoint: {PROJECT_ENDPOINT}")
    print(f"Model deployment: {MODEL_DEPLOYMENT_NAME}")
    print(f"MCP server URL:   {MCP_SERVER_URL}")
    print()


def create_agent(agents_client, mcp_tool):
    """Create an AI agent configured with the SQL MCP Server."""
    agent = agents_client.create_agent(
        model=MODEL_DEPLOYMENT_NAME,
        name="sql-data-agent",
        instructions=(
            "You are a helpful data analyst agent with access to an e-commerce SQL database "
            "through MCP tools.\n\n"
            "IMPORTANT WORKFLOW - follow these steps for EVERY data question:\n"
            "1. FIRST call describe_entities with nameOnly=false to get full metadata including field names and permissions.\n"
            "2. Use the field names from describe_entities to build your read_records calls with proper select and filter parameters.\n"
            "3. To join data across entities, make multiple read_records calls and correlate by ID fields.\n\n"
            "The database contains:\n"
            "- Category: fields include id, name, description\n"
            "- Product: fields include id, name, price, category_id\n"
            "- Customer: fields include id, first_name, last_name, email\n"
            "- Order: fields include id, customer_id, order_date, total_amount, status\n"
            "- OrderItem: fields include id, order_id, product_id, quantity, unit_price\n\n"
            "Use read_records with select, filter, and orderby to query data. "
            "When showing tabular data, use markdown tables. "
            "Always provide complete answers with actual data values."
        ),
        tools=mcp_tool.definitions,
    )
    print(f"Agent created: {agent.id}")
    return agent


def run_query(agents_client, agent, mcp_tool, query):
    """Run a single query against the agent and return the response."""
    thread = agents_client.threads.create()

    agents_client.messages.create(
        thread_id=thread.id,
        role="user",
        content=query,
    )

    mcp_tool.set_approval_mode("never")

    run = agents_client.runs.create(
        thread_id=thread.id,
        agent_id=agent.id,
        tool_resources=mcp_tool.resources,
    )

    # Poll for completion
    max_iterations = 120
    iteration = 0
    while run.status in ("queued", "in_progress", "requires_action") and iteration < max_iterations:
        time.sleep(2)
        run = agents_client.runs.get(thread_id=thread.id, run_id=run.id)
        iteration += 1

        if run.status == "requires_action" and isinstance(
            run.required_action, SubmitToolApprovalAction
        ):
            tool_approvals = []
            for tool_call in run.required_action.submit_tool_approval.tool_calls:
                if isinstance(tool_call, RequiredMcpToolCall):
                    tool_approvals.append(
                        ToolApproval(
                            tool_call_id=tool_call.id,
                            approve=True,
                            headers=mcp_tool.headers,
                        )
                    )
            if tool_approvals:
                agents_client.runs.submit_tool_outputs(
                    thread_id=thread.id,
                    run_id=run.id,
                    tool_approvals=tool_approvals,
                )

    if run.status == "failed":
        print(f"  Run failed: {run.last_error}")
        return None

    # Get the assistant's response
    messages = agents_client.messages.list(
        thread_id=thread.id,
        order=ListSortOrder.ASCENDING,
    )

    response_text = None
    for msg in messages:
        if msg.role == "assistant" and msg.text_messages:
            response_text = msg.text_messages[-1].text.value

    return response_text


def main():
    validate_config()

    credential = DefaultAzureCredential()
    project_client = AIProjectClient(
        endpoint=PROJECT_ENDPOINT,
        credential=credential,
    )

    mcp_tool = McpTool(
        server_label="dab_sql_mcp",
        server_url=MCP_SERVER_URL,
    )

    with project_client:
        agents_client = project_client.agents
        agent = create_agent(agents_client, mcp_tool)

        try:
            for i, query in enumerate(TEST_QUERIES, 1):
                if i > 1:
                    print("Waiting 15s to avoid rate limiting...")
                    time.sleep(15)
                print(f"{'='*70}")
                print(f"Query {i}/{len(TEST_QUERIES)}: {query}")
                print(f"{'='*70}")

                response = run_query(agents_client, agent, mcp_tool, query)
                if response:
                    print(f"\nAgent response:\n{response}\n")
                else:
                    print("\n  No response received.\n")

        finally:
            agents_client.delete_agent(agent.id)
            print(f"\nAgent {agent.id} deleted. Done.")


if __name__ == "__main__":
    main()
