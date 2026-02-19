FROM mcr.microsoft.com/dotnet/sdk:8.0

# Install DAB CLI
RUN dotnet tool install --global Microsoft.DataApiBuilder --prerelease
ENV PATH="$PATH:/root/.dotnet/tools"

# Copy configuration
WORKDIR /App
COPY dab-config.json /App/dab-config.json

EXPOSE 5000

ENTRYPOINT ["dab", "start", "--config", "/App/dab-config.json"]
