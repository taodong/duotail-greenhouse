# -----------------------------------------------------------------------------
# BASE IMAGE: Playwright v1.58.2 on Ubuntu 24.04 (Noble)
# -----------------------------------------------------------------------------
FROM mcr.microsoft.com/playwright:v1.58.2-noble

# Target Architecture (automatically set to arm64 on Mac, amd64 on Cloud)
ARG TARGETARCH

USER root

# -----------------------------------------------------------------------------
# 1. SYSTEM TOOLS & REPOSITORIES
# -----------------------------------------------------------------------------
RUN apt-get update && apt-get install -y \
    wget gnupg software-properties-common curl \
    git xvfb psmisc supervisor x11-utils jq \
    python3 python3-pip python3-venv iproute2 \
    && rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 2. JAVA 25 (ECLIPSE TEMURIN) INSTALLATION
# -----------------------------------------------------------------------------
RUN mkdir -p /etc/apt/keyrings && \
    wget -O - https://packages.adoptium.net/artifactory/api/gpg/key/public | gpg --dearmor > /etc/apt/keyrings/adoptium.gpg && \
    echo "deb [signed-by=/etc/apt/keyrings/adoptium.gpg] https://packages.adoptium.net/artifactory/deb noble main" | tee /etc/apt/sources.list.d/adoptium.list && \
    apt-get update && apt-get install -y temurin-25-jdk && \
    rm -rf /var/lib/apt/lists/*

# Architecture-agnostic Java Home via symlink
RUN ln -s /usr/lib/jvm/temurin-25-jdk-* /usr/lib/jvm/java-25
ENV JAVA_HOME=/usr/lib/jvm/java-25
ENV PATH="${JAVA_HOME}/bin:${PATH}"

# -----------------------------------------------------------------------------
# 3. Install Playwright MCP
# -----------------------------------------------------------------------------
# 1. Pre-install the package globally so 'npx' finds it instantly
RUN npm install -g @playwright/mcp@latest

# 2. Create the Playwright service folder (Hidden from Agent)
RUN mkdir -p /services/playwright && \
    chown root:root /services/playwright && \
    chmod 700 /services/playwright

# 3. Initialize the system-level YAML file
RUN echo "allowed:" > /services/playwright/allowed-domains.yaml && \
    echo "  - http://localhost" >> /services/playwright/allowed-domains.yaml


# -----------------------------------------------------------------------------
# 4. Install Email Sending MCP
# -----------------------------------------------------------------------------
# 1. Create a separate folder that the agent CANNOT enter
RUN mkdir -p /services/email && chmod 700 /services/email
RUN mkdir -p /var/log/duotail-test-email-sender

# 2. Put the JAR and default configurations there (Owned by Root)
COPY --chown=root:root files/binary/email-mcp.jar /services/email/email-mcp.jar
COPY --chown=root:root files/configs/email-mcp.properties /services/email/email-mcp.properties

# -----------------------------------------------------------------------------
# 5. SECURITY: AGENT USER & DIRECTORY SETUP
# -----------------------------------------------------------------------------
RUN groupadd -g 2000 agentgroup && \
    useradd -u 2000 -g agentgroup -m -s /bin/bash agentuser

WORKDIR /agent

# Create the structure:
# - /instructions & /tasks: Read-Only (Agent cannot overwrite its own rules)
# - /outputs & /screenshots: Writeable
RUN mkdir -p /agent/instructions /agent/tasks /agent/outputs /agent/screenshots /agent/bin && \
    chown root:agentgroup /agent/instructions /agent/tasks && \
    chmod 550 /agent/instructions /agent/tasks && \
    chown agentuser:agentgroup /agent/outputs /agent/screenshots /agent/bin && \
    chmod 770 /agent/outputs /agent/screenshots /agent/bin

# -----------------------------------------------------------------------------
# 6. AGENT CODE & STARTUP SCRIPT
# -----------------------------------------------------------------------------
# ARG REPO_URL
RUN chown agentuser:agentgroup /agent

USER agentuser

# Clone agent code and install dependencies
#RUN git clone ${REPO_URL} . && \
#    npm install && \
#    pip install --no-cache-dir playwright --break-system-packages

# -----------------------------------------------------------------------------
# 7. MANAGER SCRIPTS
# -----------------------------------------------------------------------------
USER root

# Install manager scripts
COPY files/scripts/run-qa.sh /usr/local/bin/run-qa
COPY files/scripts/playwright-mcp.sh /usr/local/bin/playwright-mcp
COPY files/scripts/email-mcp.sh /usr/local/bin/email-mcp

# Only Root can see or run these scripts
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

# Keep the container alive indefinitely without running the agent
# Supervisor runs in the background but starts NO programs initially
ENTRYPOINT ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]