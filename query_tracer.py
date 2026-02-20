"""
SQL Query Tracer — Streamlit UI

Traces and visualizes the SQL queries that Data API Builder generates
when the AI Agent invokes MCP tools against the e-commerce database.

Usage:
    streamlit run query_tracer.py
"""

import json
import os
import struct
import subprocess
import sys
from datetime import datetime, timezone

import pandas as pd
import pyodbc
import streamlit as st
from azure.identity import AzureCliCredential
from dotenv import load_dotenv

load_dotenv()

SQL_SERVER = os.environ.get("SQL_SERVER", "sql-mcp-pietrobr.database.windows.net")
SQL_DATABASE = os.environ.get("SQL_DATABASE", "OrdersDB")
ODBC_DRIVER = os.environ.get("ODBC_DRIVER", "ODBC Driver 17 for SQL Server")

# DAB table → MCP entity mapping
TABLE_ENTITY = {
    "Products": "Product",
    "Categories": "Category",
    "Customers": "Customer",
    "Orders": "Order",
    "OrderItems": "OrderItem",
}

st.set_page_config(page_title="SQL Query Tracer", page_icon="🔍", layout="wide")

# ── Palette ──────────────────────────────────────────────────
TYPE_ICON = {
    "SELECT": "🔵",
    "INSERT": "🟢",
    "UPDATE": "🟡",
    "DELETE": "🔴",
    "EXEC": "🟣",
    "OTHER": "⚪",
}


# ── Connection ───────────────────────────────────────────────
def _new_connection():
    cred = AzureCliCredential()
    tok = cred.get_token("https://database.windows.net/.default")
    raw = tok.token.encode("UTF-16-LE")
    token_struct = struct.pack(f"<I{len(raw)}s", len(raw), raw)
    return pyodbc.connect(
        f"Driver={{{ODBC_DRIVER}}};"
        f"Server={SQL_SERVER};Database={SQL_DATABASE};"
        "Encrypt=yes;TrustServerCertificate=no;",
        attrs_before={1256: token_struct},
    )


def get_conn():
    """Return a live pyodbc connection, reconnecting when needed."""
    c = st.session_state.get("_conn")
    if c is not None:
        try:
            cur = c.cursor()
            cur.execute("SELECT 1")
            cur.close()
            return c
        except Exception:
            try:
                c.close()
            except Exception:
                pass
    st.session_state["_conn"] = _new_connection()
    return st.session_state["_conn"]


# ── Data fetchers ────────────────────────────────────────────
def load_query_store(conn, mins):
    cur = conn.cursor()
    cur.execute("EXEC sp_query_store_flush_db")
    conn.commit()
    cur.close()

    sql = """
    SELECT TOP 200
        qt.query_sql_text,
        q.query_id,
        rs.count_executions,
        CAST(rs.avg_duration    / 1000.0 AS DECIMAL(18,2)) AS avg_duration_ms,
        CAST(rs.last_duration   / 1000.0 AS DECIMAL(18,2)) AS last_duration_ms,
        CAST(rs.avg_cpu_time    / 1000.0 AS DECIMAL(18,2)) AS avg_cpu_ms,
        CAST(rs.avg_logical_io_reads AS INT)                AS avg_reads,
        CAST(rs.avg_rowcount         AS INT)                AS avg_rows,
        CAST(rs.last_execution_time  AS datetime2)           AS last_execution_time,
        CAST(rs.first_execution_time AS datetime2)           AS first_execution_time
    FROM sys.query_store_query_text        AS qt
    JOIN sys.query_store_query             AS q  ON qt.query_text_id = q.query_text_id
    JOIN sys.query_store_plan              AS p  ON q.query_id       = p.query_id
    JOIN sys.query_store_runtime_stats     AS rs ON p.plan_id        = rs.plan_id
    WHERE rs.last_execution_time >= DATEADD(MINUTE, ?, GETUTCDATE())
      AND qt.query_sql_text NOT LIKE '%sys.query_store%'
      AND qt.query_sql_text NOT LIKE '%sys.dm_exec%'
      AND qt.query_sql_text NOT LIKE '%sp_query_store_flush%'
    ORDER BY rs.last_execution_time DESC
    """
    return pd.read_sql(sql, conn, params=[-mins])


def load_dmv(conn, mins):
    sql = """
    SELECT TOP 200
        SUBSTRING(st.text, (qs.statement_start_offset/2)+1,
            ((CASE qs.statement_end_offset
                WHEN -1 THEN DATALENGTH(st.text)
                ELSE qs.statement_end_offset END
              - qs.statement_start_offset)/2) + 1)              AS query_sql_text,
        qs.execution_count                                       AS count_executions,
        CAST(qs.last_elapsed_time / 1000.0 AS DECIMAL(18,2))    AS last_duration_ms,
        CAST(CASE WHEN qs.execution_count > 0
             THEN qs.total_elapsed_time / qs.execution_count / 1000.0
             ELSE 0 END AS DECIMAL(18,2))                        AS avg_duration_ms,
        CAST(qs.last_worker_time / 1000.0 AS DECIMAL(18,2))     AS avg_cpu_ms,
        qs.last_logical_reads                                    AS avg_reads,
        qs.last_rows                                             AS avg_rows,
        CAST(qs.last_execution_time AS datetime2)                AS last_execution_time
    FROM sys.dm_exec_query_stats AS qs
    CROSS APPLY sys.dm_exec_sql_text(qs.sql_handle) AS st
    WHERE qs.last_execution_time >= DATEADD(MINUTE, ?, GETUTCDATE())
      AND st.text NOT LIKE '%dm_exec_query_stats%'
      AND st.text NOT LIKE '%query_store%'
    ORDER BY qs.last_execution_time DESC
    """
    return pd.read_sql(sql, conn, params=[-mins])


# ── Classifiers ──────────────────────────────────────────────
def classify(sql_text):
    upper = sql_text.strip().upper()
    qtype = "OTHER"
    for kw in ("SELECT", "INSERT", "UPDATE", "DELETE", "EXEC"):
        if upper.startswith(kw):
            qtype = kw
            break

    tables = [t for t in TABLE_ENTITY if t.lower() in sql_text.lower()]
    entities = [TABLE_ENTITY[t] for t in tables]

    mcp_map = {
        "SELECT": "read_records",
        "INSERT": "create_record",
        "UPDATE": "update_record",
        "DELETE": "delete_record",
    }
    if entities and qtype in mcp_map:
        mcp = f"{mcp_map[qtype]}({', '.join(entities)})"
    else:
        mcp = "describe_entities?" if qtype == "SELECT" else "—"

    return qtype, ", ".join(tables) or "—", mcp


def is_system(text):
    marks = [
        "sys.", "information_schema", "query_store", "dm_exec",
        "sp_reset_connection", "@@", "sp_trace", "xp_",
    ]
    low = text.lower()
    return any(m in low for m in marks)


def load_trace_log():
    """Load the trace_log.json file written by test_agent.py, if present."""
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "trace_log.json")
    if not os.path.exists(path):
        return None
    with open(path, "r", encoding="utf-8") as f:
        data = json.load(f)
    for entry in data:
        entry["start_dt"] = datetime.fromisoformat(entry["start_utc"])
        entry["end_dt"] = datetime.fromisoformat(entry["end_utc"])
    return data


AGENT_COLORS = ["#1E88E5", "#43A047", "#FB8C00", "#8E24AA", "#E53935", "#00ACC1"]


# ═══════════════════════════════════════════════════════════════
# SIDEBAR
# ═══════════════════════════════════════════════════════════════
with st.sidebar:
    st.header("⚙️  Settings")
    st.markdown(f"**Server:** `{SQL_SERVER}`")
    st.markdown(f"**DB:** `{SQL_DATABASE}`")

    try:
        conn = get_conn()
        st.success("● Connected (Azure AD)")
    except Exception as exc:
        st.error(f"Connection failed: {exc}")
        st.info("Run `az login` first, then reload.")
        st.stop()

    st.divider()
    minutes = st.slider("⏱️  Time window (min)", 5, 360, 60, 5)
    show_sys = st.checkbox("Show system queries", False)
    sel_types = st.multiselect(
        "Query types",
        ["SELECT", "INSERT", "UPDATE", "DELETE", "EXEC", "OTHER"],
        default=["SELECT", "INSERT", "UPDATE", "DELETE"],
    )
    sel_tables = st.multiselect(
        "Filter tables (empty = all)",
        list(TABLE_ENTITY.keys()),
    )
    st.divider()
    source = st.radio("Data source", ["Query Store", "DMV (Plan Cache)"])


# ═══════════════════════════════════════════════════════════════
# MAIN — Header & actions
# ═══════════════════════════════════════════════════════════════
st.title("🔍 SQL Query Tracer")
st.caption(
    "Visualizza le query SQL generate da **Data API Builder** quando l'agente AI "
    "esegue tool MCP sul database e-commerce."
)

# ── Action buttons row ───────────────────────────────────────
c1, c2, c3, c4 = st.columns(4)
with c1:
    run_agent = st.button(
        "▶️  Lancia Agent Test", type="primary", use_container_width=True,
    )
with c2:
    st.button("🔄  Aggiorna Query", use_container_width=True)
with c3:
    test_query = st.button("🧪  Test Query", use_container_width=True)
with c4:
    clear_qs = st.button("🗑️  Pulisci Query Store", use_container_width=True)

# ── Custom agent query ───────────────────────────────────────
st.markdown("---")
cq_col1, cq_col2 = st.columns([5, 1])
with cq_col1:
    custom_query = st.text_input(
        "💬 Chiedi all'agente",
        placeholder="es: Qual è il prodotto più venduto per quantità?",
        value="",
        label_visibility="collapsed",
    )
with cq_col2:
    send_custom = st.button("🚀  Invia", use_container_width=True, disabled=not custom_query)
st.caption(
    "Scrivi una domanda in linguaggio naturale e l'agente la eseguirà tramite MCP → DAB → SQL. "
    "Esempio: *Qual è il prodotto più venduto per quantità?*"
)

if clear_qs:
    try:
        ac = _new_connection()
        ac.autocommit = True
        ac.cursor().execute("ALTER DATABASE [OrdersDB] SET QUERY_STORE CLEAR")
        ac.close()
        # Also clear the trace log so stale entries don't stick around
        tl_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "trace_log.json")
        if os.path.exists(tl_path):
            os.remove(tl_path)
        st.success("✅ Query Store e trace log svuotati. Clicca 🔄 per aggiornare.")
    except Exception as e:
        st.error(f"Errore pulizia: {e}")

if test_query:
    try:
        cur = conn.cursor()
        cur.execute("SELECT TOP 3 p.name, p.price, c.name AS category FROM dbo.Products p JOIN dbo.Categories c ON p.category_id = c.id ORDER BY p.price DESC")
        rows = cur.fetchall()
        cur.close()
        st.success(f"✅ Test OK — {len(rows)} righe restituite")
        for r in rows:
            st.write(f"  • **{r[0]}** — €{r[1]} ({r[2]})")
        st.caption("Questa query apparirà nel tracer dopo il refresh.")
    except Exception as e:
        st.error(f"Test query fallita: {e}")


def _run_agent_subprocess(extra_args=None):
    """Run test_agent.py as a subprocess, optionally with extra CLI args."""
    env = os.environ.copy()
    env["PATH"] = (
        r"C:\Program Files\Microsoft SDKs\Azure\CLI2\wbin;"
        + env.get("PATH", "")
    )
    cmd = [sys.executable, "test_agent.py"] + (extra_args or [])
    try:
        res = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            cwd=os.path.dirname(os.path.abspath(__file__)),
            env=env,
            timeout=600,
        )
        st.session_state["a_out"] = res.stdout
        st.session_state["a_err"] = res.stderr
        st.session_state["a_rc"] = res.returncode
    except subprocess.TimeoutExpired:
        st.error("Timeout dopo 10 min")
    except Exception as e:
        st.error(f"Errore: {e}")


if run_agent:
    with st.spinner("🤖 Agent in esecuzione (~2 min per 5 query)…"):
        _run_agent_subprocess()

if send_custom and custom_query:
    with st.spinner(f"🤖 Invio all'agente: *{custom_query[:80]}*…"):
        _run_agent_subprocess(["--query", custom_query])

if st.session_state.get("a_out"):
    with st.expander("📋 Output dell'agent", expanded=False):
        rc = st.session_state.get("a_rc", 0)
        (st.success if rc == 0 else st.error)(
            f"{'Completato' if rc == 0 else 'Fallito'} (exit {rc})"
        )
        st.code(st.session_state["a_out"][:8000], language="text")

st.divider()

# ═══════════════════════════════════════════════════════════════
# MAIN — Query Store diagnostics
# ═══════════════════════════════════════════════════════════════
with st.expander("🔧 Diagnostica Query Store", expanded=False):
    try:
        diag = pd.read_sql(
            "SELECT actual_state_desc, readonly_reason, "
            "desired_state_desc, current_storage_size_mb, max_storage_size_mb "
            "FROM sys.database_query_store_options",
            conn,
        )
        d = diag.iloc[0]
        st.markdown(
            f"**Stato:** {d['actual_state_desc']}  \n"
            f"**Desiderato:** {d['desired_state_desc']}  \n"
            f"**Storage:** {d['current_storage_size_mb']} / {d['max_storage_size_mb']} MB"
        )
        if d["actual_state_desc"] != "READ_WRITE":
            st.warning(
                "Query Store non è in READ_WRITE. "
                "Esegui: `ALTER DATABASE [OrdersDB] SET QUERY_STORE = ON (OPERATION_MODE = READ_WRITE);`"
            )
        cnt = pd.read_sql(
            "SELECT COUNT(*) AS n FROM sys.query_store_query_text", conn
        ).iloc[0]["n"]
        st.markdown(f"**Query testi totali nel Query Store:** {cnt}")
    except Exception as e:
        st.error(f"Diagnostica fallita: {e}")

# ═══════════════════════════════════════════════════════════════
# MAIN — Load queries
# ═══════════════════════════════════════════════════════════════
try:
    df = (
        load_query_store(conn, minutes)
        if source == "Query Store"
        else load_dmv(conn, minutes)
    )
except Exception as exc:
    st.error(f"Errore nella query: {exc}")
    st.session_state["_conn"] = None
    st.stop()

if df.empty:
    st.info(
        f"Nessuna query trovata negli ultimi {minutes} minuti. "
        "Lancia l'agent test o amplia la finestra temporale."
    )
    st.stop()

# ── Classify & filter ────────────────────────────────────────
clf = df["query_sql_text"].apply(classify)
df["query_type"] = clf.apply(lambda x: x[0])
df["tables"] = clf.apply(lambda x: x[1])
df["mcp_tool"] = clf.apply(lambda x: x[2])
df["is_sys"] = df["query_sql_text"].apply(is_system)

if not show_sys:
    df = df[~df["is_sys"]]
if sel_types:
    df = df[df["query_type"].isin(sel_types)]
if sel_tables:
    df = df[df["tables"].apply(lambda t: any(s in t for s in sel_tables))]
df = df.reset_index(drop=True)

if df.empty:
    st.info("Tutte le query sono state filtrate. Modifica i filtri nella sidebar.")
    st.stop()

# ═══════════════════════════════════════════════════════════════
# MAIN — Metrics
# ═══════════════════════════════════════════════════════════════
m1, m2, m3, m4 = st.columns(4)
m1.metric("Query totali", len(df))
m2.metric("Durata media", f"{df['avg_duration_ms'].mean():.1f} ms")
m3.metric("Righe totali", f"{int(df['avg_rows'].sum()):,}")
m4.metric("Tabelle coinvolte", df["tables"].nunique())

# ── Duration chart ───────────────────────────────────────────
if "last_execution_time" in df.columns and len(df) > 1:
    try:
        import altair as alt

        chart_df = df[
            ["last_execution_time", "last_duration_ms", "query_type"]
        ].rename(
            columns={
                "last_execution_time": "Ora",
                "last_duration_ms": "Durata (ms)",
                "query_type": "Tipo",
            }
        )
        chart = (
            alt.Chart(chart_df)
            .mark_bar(cornerRadiusTopLeft=3, cornerRadiusTopRight=3)
            .encode(
                x=alt.X("Ora:T", title="Ora esecuzione"),
                y=alt.Y("Durata (ms):Q"),
                color=alt.Color(
                    "Tipo:N",
                    scale=alt.Scale(
                        domain=["SELECT", "INSERT", "UPDATE", "DELETE"],
                        range=["#4A90D9", "#27AE60", "#F39C12", "#E74C3C"],
                    ),
                ),
                tooltip=["Ora:T", "Durata (ms):Q", "Tipo:N"],
            )
            .properties(height=220)
        )
        st.altair_chart(chart, use_container_width=True)
    except Exception:
        pass

st.divider()

# ═══════════════════════════════════════════════════════════════
# MAIN — Query details (grouped by agent query when trace_log exists)
# ═══════════════════════════════════════════════════════════════
trace_log = load_trace_log()

if trace_log and not df.empty and "last_execution_time" in df.columns:
    # ── Grouped view: Agent Query → SQL Queries ──────────────
    st.subheader("🤖 Agent Query → SQL Query Mapping")
    st.caption(
        "Ogni blocco mostra la domanda inviata all'agente e le query SQL "
        "che DAB ha generato sul database in risposta."
    )

    # Make last_execution_time timezone-aware (UTC) for comparison
    df["exec_ts"] = pd.to_datetime(df["last_execution_time"], utc=True)
    BUFFER_SEC = 30  # generous buffer for clock skew between local machine and Azure SQL

    # Filter trace_log to only entries within the current time window
    cutoff = datetime.now(timezone.utc) - pd.Timedelta(minutes=minutes)
    trace_log = [e for e in trace_log if e["end_dt"] >= cutoff]

    matched_indices = set()

    for i, entry in enumerate(trace_log):
        color = AGENT_COLORS[i % len(AGENT_COLORS)]
        start = entry["start_dt"] - pd.Timedelta(seconds=BUFFER_SEC)
        end = entry["end_dt"] + pd.Timedelta(seconds=BUFFER_SEC)

        # Find SQL queries within the time window
        mask = (df["exec_ts"] >= start) & (df["exec_ts"] <= end)
        group_df = df[mask]
        matched_indices.update(group_df.index.tolist())

        # Agent query card
        st.markdown(
            f'<div style="background:{color}22; border-left:4px solid {color}; '
            f'padding:12px 16px; border-radius:6px; margin-bottom:4px;">'
            f'<span style="color:{color}; font-weight:700; font-size:1.1em;">'
            f'🤖 Query {entry["index"]}</span>'
            f'<br/><span style="font-size:1.05em; font-weight:500;">'
            f'{entry["query"]}</span></div>',
            unsafe_allow_html=True,
        )

        if group_df.empty:
            st.info("  Nessuna query SQL catturata per questa richiesta.")
        else:
            st.markdown(
                f"  **{len(group_df)}** query SQL generate "
                f"({entry['start_dt'].strftime('%H:%M:%S')} — "
                f"{entry['end_dt'].strftime('%H:%M:%S')} UTC)"
            )
            for _, row in group_df.iterrows():
                sql = row["query_sql_text"]
                qtype = row["query_type"]
                icon = TYPE_ICON.get(qtype, "⚪")
                dur = row.get("last_duration_ms", row.get("avg_duration_ms", 0))
                rows_count = row.get("avg_rows", "–")
                tables = row["tables"]
                mcp = row["mcp_tool"]

                st.markdown(
                    f"&nbsp;&nbsp;&nbsp;&nbsp;{icon} **{qtype}** su **{tables}** │ "
                    f"⏱ {dur} ms │ 📊 {rows_count} righe │ 🔗 `{mcp}`"
                )
                st.code(sql, language="sql")

        # Show agent response (truncated)
        if entry.get("response"):
            with st.expander(f"💬 Risposta agente (query {entry['index']})", expanded=False):
                st.markdown(entry["response"])

        st.divider()

    # ── Unmatched queries ────────────────────────────────────
    unmatched = df[~df.index.isin(matched_indices)]
    if not unmatched.empty:
        st.subheader(f"❓ Query SQL non associate ({len(unmatched)})")
        st.caption("Query eseguite nel periodo ma non abbinate a nessuna richiesta dell'agente.")
        for _, row in unmatched.iterrows():
            sql = row["query_sql_text"]
            qtype = row["query_type"]
            icon = TYPE_ICON.get(qtype, "⚪")
            dur = row.get("last_duration_ms", row.get("avg_duration_ms", 0))
            tables = row["tables"]
            ts = row.get("last_execution_time", "")
            st.markdown(
                f"{icon} **{qtype}** su **{tables}** │ ⏱ {dur} ms │ 🕐 {ts}"
            )
            st.code(sql, language="sql")
            st.divider()

else:
    # ── Flat view (no trace log available) ───────────────────
    st.subheader(f"📊 Dettaglio Query ({len(df)})")
    if not trace_log:
        st.caption(
            "💡 Lancia **▶️ Agent Test** per generare il trace log e vedere "
            "il mapping Agent Query → SQL Query."
        )

    for idx, row in df.iterrows():
        sql = row["query_sql_text"]
        qtype = row["query_type"]
        icon = TYPE_ICON.get(qtype, "⚪")
        dur = row.get("last_duration_ms", row.get("avg_duration_ms", 0))
        rows_count = row.get("avg_rows", "–")
        execs = row.get("count_executions", 1)
        tables = row["tables"]
        mcp = row["mcp_tool"]
        ts = row.get("last_execution_time", "")

        st.markdown(
            f"{icon} **{qtype}** su **{tables}**  │  "
            f"⏱ {dur} ms  │  📊 {rows_count} righe  │  🔄 {execs}×  │  "
            f"🔗 `{mcp}`  │  🕐 {ts}"
        )
        st.code(sql, language="sql")

        with st.expander("📈 Metriche dettagliate", expanded=False):
            c1, c2, c3, c4 = st.columns(4)
            c1.markdown(f"**Durata:** {dur} ms  \n**Media:** {row.get('avg_duration_ms', '–')} ms")
            c2.markdown(f"**CPU:** {row.get('avg_cpu_ms', '–')} ms")
            c3.markdown(f"**Letture IO:** {row.get('avg_reads', '–')}")
            c4.markdown(f"**MCP Tool:** `{mcp}`")

        st.divider()
