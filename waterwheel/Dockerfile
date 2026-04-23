# syntax = docker/dockerfile:1.3
# =============================================================================
# STAGE 1 – system-deps
# Contains all slow, stable OS/runtime installations.
# Only rebuilt when system-level dependencies change.
# =============================================================================
FROM mcr.microsoft.com/playwright:v1.58.2-noble AS system-deps

ARG TARGETARCH

USER root

# -----------------------------------------------------------------------------
# 1. SYSTEM TOOLS & REPOSITORIES
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y \
    wget gnupg software-properties-common curl \
    git xvfb psmisc supervisor x11-utils jq yq \
    python3 python3-pip python3-venv iproute2 \
    openssh-client \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2. JAVA 25 (ECLIPSE TEMURIN) INSTALLATION
# -----------------------------------------------------------------------------
RUN mkdir -p /etc/apt/keyrings && \
    wget -O - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor > /etc/apt/keyrings/adoptium.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb noble main" | tee /etc/apt/sources.list.d/adoptium.list && \
    apt-get update && apt-get install -y temurin-25-jdk && \
    rm -rf /var/lib/apt/lists/*

RUN ln -s /usr/lib/jvm/temurin-25-jdk-* /usr/lib/jvm/java-25
ENV JAVA_HOME=/usr/lib/jvm/java-25
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# -----------------------------------------------------------------------------
# 3. Install Playwright MCP
# -----------------------------------------------------------------------------
RUN npm install -g @playwright/mcp@0.0.70

RUN mkdir -p /services/playwright && \
    chown root:root /services/playwright && \
    chmod 700 /services/playwright

RUN npx @playwright/mcp@0.0.70 install-browser chrome-for-testing

RUN echo "allowed:" > /services/playwright/allowed-domains.yaml && \
    echo "  - http://localhost" >> /services/playwright/allowed-domains.yaml

# -----------------------------------------------------------------------------
# 4. Install Email Sending MCP
# -----------------------------------------------------------------------------
RUN mkdir -p /services/email && chmod 700 /services/email
RUN mkdir -p /var/log/duotail-test-email-sender

COPY --chown=root:root files/binary/email-mcp.jar /services/email/email-mcp.jar
COPY --chown=root:root files/configs/email-mcp.properties /services/email/email-mcp.properties

# -----------------------------------------------------------------------------
# 5. SECURITY: AGENT USER & DIRECTORY SETUP
# -----------------------------------------------------------------------------
RUN groupadd -g 2000 agentgroup && \
    useradd -u 2000 -g agentgroup -m -s /bin/bash agentuser

WORKDIR /agent

RUN mkdir -p /agent/instructions /agent/tasks /agent/outputs /agent/screenshots /agent/bin && \
    chown root:agentgroup /agent/instructions /agent/tasks && \
    chmod 550 /agent/instructions /agent/tasks && \
    chown agentuser:agentgroup /agent/outputs /agent/screenshots /agent/bin && \
    chmod 770 /agent/outputs /agent/screenshots /agent/bin


# =============================================================================
# STAGE 2 – agent-builder
# Clones the agent repo and installs its npm/pip dependencies.
# Only rebuilt when agent code or its dependencies change.
# =============================================================================
FROM system-deps AS agent-builder

USER root

RUN mkdir -p -m 0700 /root/.ssh && ssh-keyscan github.com >> /root/.ssh/known_hosts

ENV REPO_URL="git@github.com:taodong/duotail-waterwheel-agent.git"
ARG AGENT_CLONE_BUSTER=0

RUN --mount=type=ssh,required=true \
    echo "AGENT_CLONE_BUSTER=${AGENT_CLONE_BUSTER}" && \
    git clone ${REPO_URL} ./temp_repo && \
    cp -a ./temp_repo/. . && \
    rm -rf ./temp_repo/.git ./temp_repo

RUN chown -R agentuser:agentgroup /agent

USER agentuser

RUN npm install && \
    pip install --no-cache-dir playwright --break-system-packages


# =============================================================================
# STAGE 3 – final
# Assembles the runtime image from the two previous stages.
# =============================================================================
FROM system-deps AS final

# Copy the fully-installed agent workspace from the builder stage
COPY --from=agent-builder --chown=agentuser:agentgroup /agent /agent

# -----------------------------------------------------------------------------
# 7. MANAGER SCRIPTS
# -----------------------------------------------------------------------------
USER root

COPY files/scripts/run-qa.sh /usr/local/bin/run-qa
COPY files/scripts/playwright-mcp.sh /usr/local/bin/playwright-mcp
COPY files/scripts/email-mcp.sh /usr/local/bin/email-mcp

RUN chown root:root /usr/local/bin/playwright-mcp \
                   /usr/local/bin/email-mcp \
                   /usr/local/bin/run-qa && \
    chmod 700 /usr/local/bin/playwright-mcp \
              /usr/local/bin/email-mcp \
              /usr/local/bin/run-qa

# -----------------------------------------------------------------------------
# 8. SUPERVISOR CONFIGURATION
# -----------------------------------------------------------------------------
COPY files/configs/supervisord.conf /etc/supervisor/conf.d/mcp-services.conf

# -----------------------------------------------------------------------------
# 9. RUNTIME ENVIRONMENT (IDLE MODE)
# -----------------------------------------------------------------------------
ENV DISPLAY=:99
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]