# DevOps.Agents: il servizio (API, smistatore, supervisore, dashboard) in un'immagine sola.
# Si costruisce dalla radice del repo:  docker build -f app/Dockerfile -t devops-agents .
# Contiene gli attrezzi del repo (config, ruoli, regole, hook, src/card.ps1 e src/memoria.ps1) e le CLI che usano le sessioni:
# git, Claude Code (npm) e PowerShell 7 (card.ps1, memoria.ps1 e gli hook).
# Dietro un proxy con certificato proprio:  docker build --secret id=ca,src=<certificato.pem> --build-arg HTTPS_PROXY=... ...

ARG NODE_IMAGE=node:20-bookworm-slim
FROM ${NODE_IMAGE} AS frontend
WORKDIR /src/app/frontend
COPY app/frontend/package.json app/frontend/package-lock.json ./
RUN --mount=type=secret,id=ca,required=false if [ -f /run/secrets/ca ]; then export SSL_CERT_FILE=/run/secrets/ca NODE_EXTRA_CA_CERTS=/run/secrets/ca; fi; npm ci --no-audit --no-fund
COPY app/frontend/ ./
# angular.json scrive in app/backend/src/DevOpsAgents.Api/wwwroot (senza la cartella browser/)
RUN npx ng build

FROM mcr.microsoft.com/dotnet/sdk:8.0-bookworm-slim AS backend
WORKDIR /src
COPY app/backend/ app/backend/
COPY config/ config/
COPY ruoli/ ruoli/
RUN --mount=type=secret,id=ca,required=false if [ -f /run/secrets/ca ]; then export SSL_CERT_FILE=/run/secrets/ca NODE_EXTRA_CA_CERTS=/run/secrets/ca; fi; dotnet publish app/backend/src/DevOpsAgents.Api -c Release -o /out/server --nologo \
 && dotnet publish app/backend/src/DevOpsAgents.Cli -c Release -o /out/cli --nologo

FROM mcr.microsoft.com/dotnet/aspnet:8.0-bookworm-slim
ARG PWSH_VERSION=7.4.6
RUN --mount=type=secret,id=ca,required=false if [ -f /run/secrets/ca ]; then export SSL_CERT_FILE=/run/secrets/ca NODE_EXTRA_CA_CERTS=/run/secrets/ca; fi; apt-get update \
 && apt-get install -y --no-install-recommends git ca-certificates curl nodejs npm libicu72 \
 && npm install -g @anthropic-ai/claude-code \
 && curl -fsSL -o /tmp/pwsh.tgz "https://github.com/PowerShell/PowerShell/releases/download/v${PWSH_VERSION}/powershell-${PWSH_VERSION}-linux-x64.tar.gz" \
 && mkdir -p /opt/pwsh && tar xzf /tmp/pwsh.tgz -C /opt/pwsh && chmod +x /opt/pwsh/pwsh && ln -s /opt/pwsh/pwsh /usr/local/bin/pwsh \
 && rm -rf /tmp/pwsh.tgz /var/lib/apt/lists/* /root/.npm
# gli attrezzi del repo: la configurazione e i brief li legge il servizio, card.ps1 e memoria.ps1 li usano le sessioni
COPY config/ /opt/devops-agents/config/
COPY ruoli/ /opt/devops-agents/ruoli/
COPY regole/ /opt/devops-agents/regole/
COPY skills/ /opt/devops-agents/skills/
COPY hooks/ /opt/devops-agents/hooks/
COPY memoria/ /opt/devops-agents/memoria/
COPY src/ /opt/devops-agents/src/
COPY --from=backend /out/server /opt/devops-agents/server/
COPY --from=frontend /src/app/backend/src/DevOpsAgents.Api/wwwroot /opt/devops-agents/server/wwwroot/
COPY --from=backend /out/cli /opt/devops-agents/cli/
RUN ln -s /opt/devops-agents/cli/devops-agents /usr/local/bin/devops-agents \
 && useradd --create-home --uid 1000 agenti && mkdir -p /dati /repos && chown agenti /dati /repos
USER agenti
# dentro il container si ascolta su tutte le interfacce: la porta si pubblica solo su localhost (vedi docker-compose.yml)
ENV Urls=http://0.0.0.0:18800 \
    AllowedHosts="localhost;127.0.0.1" \
    DevOpsAgents__Root=/opt/devops-agents \
    DevOpsAgents__DataDir=/dati \
    DevOpsAgents__WorktreeRoot=/repos/_wt \
    DOTNET_CLI_TELEMETRY_OPTOUT=1
WORKDIR /opt/devops-agents/server
EXPOSE 18800
HEALTHCHECK --interval=30s --timeout=5s CMD curl -fsS http://localhost:18800/api/status || exit 1
ENTRYPOINT ["dotnet", "DevOpsAgents.Api.dll"]
