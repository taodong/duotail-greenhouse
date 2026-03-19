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
    git xvfb psmisc \
    python3 python3-pip python3-venv \
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
# 3. Install Email Sending MCP
# -----------------------------------------------------------------------------
# 1. Create a separate folder that the agent CANNOT enter
RUN mkdir -p /services/email && chown root:root /services/email && chmod 700 /services/email

# 2. Put the JAR there (Owned by Root)
COPY --chown=root:root files/binary/email-mcp.jar /services/email/email-mcp.jar

# -----------------------------------------------------------------------------
# 4. SECURITY: USER & DIRECTORY SETUP
# -----------------------------------------------------------------------------
RUN groupadd -g 1001 agentgroup && \
    useradd -u 1001 -g agentgroup -m -s /bin/bash agentuser

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
# 5. AGENT CODE & STARTUP SCRIPT
# -----------------------------------------------------------------------------
# ARG REPO_URL
RUN chown agentuser:agentgroup /agent

USER agentuser

# Clone agent code and install dependencies
RUN git clone ${REPO_URL} . && \
    npm install && \
    pip install --no-cache-dir playwright --break-system-packages

# -----------------------------------------------------------------------------
# 6. MANAGER SCRIPTS
# -----------------------------------------------------------------------------
# Move start.sh to /usr/local/bin/run-qa
COPY file/scripts/run-qa.sh /usr/local/bin/run-qa

# Only Root can see or run this script
RUN chown root:root /usr/local/bin/run-qa && \
    chmod 700 /usr/local/bin/run-qa

# -----------------------------------------------------------------------------
# 7. RUNTIME ENVIRONMENT (IDLE MODE)
# -----------------------------------------------------------------------------
ENV DISPLAY=:99
ENV PYTHONUNBUFFERED=1

# Keep the container alive indefinitely without running the agent
# This allows you to 'docker exec' in when ready.
ENTRYPOINT ["tail", "-f", "/dev/null"]