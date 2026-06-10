# syntax = docker/dockerfile:1.3
# =============================================================================
# STAGE 1 – system-deps
# Contains all slow, stable OS/runtime installations.
# Only rebuilt when system-level dependencies change.
# =============================================================================
FROM mcr.microsoft.com/playwright:v1.60.0-noble AS system-deps

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
# 1b. SECURITY: PATCH VULNERABLE SYSTEM PYTHON PACKAGES
# 1. Remove the apt-managed python3-jwt (pip cannot uninstall it - no RECORD).
# 2. Install patched versions into /usr/local (which takes import precedence).
# 3. Delete the stale apt-installed copies left in /usr/lib/python3 so that
#    vulnerability scanners no longer detect the old dist-info metadata.
# -----------------------------------------------------------------------------
RUN apt-get update && \
    apt-get remove -y python3-jwt python3-cryptography && \
    rm -rf /var/lib/apt/lists/* && \
    pip install --no-cache-dir --break-system-packages --upgrade --ignore-installed \
        "cryptography>=46.0.5" \
        "pyjwt>=2.12.0" \
        "setuptools>=78.1.1" \
        "wheel>=0.46.2" && \
    rm -rf /usr/lib/python3/dist-packages/cryptography*.dist-info \
           /usr/lib/python3/dist-packages/cryptography*.egg-info \
           /usr/lib/python3/dist-packages/cryptography \
           /usr/lib/python3/dist-packages/setuptools-68.1.2.egg-info \
           /usr/lib/python3/dist-packages/wheel-0.42.0.dist-info \
           /usr/lib/python3/dist-packages/wheel

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

# Keep npm current in the base stage so downstream npm/npx commands share one version.
ARG NPM_VERSION=11.16.0
RUN npm install -g npm@${NPM_VERSION}

# -----------------------------------------------------------------------------
    # 3. Install Playwright MCP
# -----------------------------------------------------------------------------
ARG PLAYWRIGHT_MCP_VERSION=0.0.75
ENV PLAYWRIGHT_MCP_VERSION=${PLAYWRIGHT_MCP_VERSION}
RUN npm install -g @playwright/mcp@${PLAYWRIGHT_MCP_VERSION}

RUN mkdir -p /services/playwright && \
    chown root:root /services/playwright && \
    chmod 700 /services/playwright

RUN node $(npm root -g)/@playwright/mcp/node_modules/playwright-core/cli.js install chromium

COPY --chown=root:root files/configs/playwright-mcp-config.json /services/playwright/playwright-mcp-config.json

RUN echo "allowed:" > /services/playwright/allowed-domains.yaml && \
    echo "  - http://localhost;about:blank" >> /services/playwright/allowed-domains.yaml

ENV ENABLE_PLAYWRIGHT_MCP=true

# -----------------------------------------------------------------------------
# 4. Install Email Sending MCP
# -----------------------------------------------------------------------------
ARG EMAIL_MCP_VERSION=0.4.1
ARG EMAIL_MCP_JAR_URL=https://github.com/taodong/duotail-test-sender/releases/download/v${EMAIL_MCP_VERSION}/duotail-test-email-utils-${EMAIL_MCP_VERSION}.jar
RUN mkdir -p /services/email && chmod 700 /services/email
RUN mkdir -p /var/log/email-mcp

RUN wget -O /services/email/email-mcp.jar ${EMAIL_MCP_JAR_URL} && \
    chown root:root /services/email/email-mcp.jar
COPY --chown=root:root files/configs/email-mcp.properties /services/email/email-mcp.properties

ENV ENABLE_EMAIL_MCP=true

# -----------------------------------------------------------------------------
# 5. SECURITY: AGENT USER & DIRECTORY SETUP
# -----------------------------------------------------------------------------
RUN groupadd -g 2000 agentgroup && \
    useradd -u 2000 -g agentgroup -m -s /bin/bash agentuser

WORKDIR /agent

RUN mkdir -p /agent/instructions /agent/tasks /agent/outputs /agent/bin && \
    chown root:agentgroup /agent/instructions /agent/tasks && \
    chmod 550 /agent/instructions /agent/tasks && \
    chown agentuser:agentgroup /agent/outputs /agent/bin && \
    chmod 770 /agent/outputs /agent/bin


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

USER root

# Install obfuscation tooling with root permissions so global npm writes succeed.
RUN npm install -g terser

USER agentuser

# Install npm and python dependencies first
RUN npm install && \
    pip install --no-cache-dir playwright --break-system-packages

# Compile TypeScript runtime artifacts from the project's build script.
RUN npm run build --if-present


# Remove source code folders and keep only config and essential runtime files
RUN cd /agent && \
    find . -maxdepth 1 -type d \
      -not -name "node_modules" \
      -not -name "config" \
      -not -name "dist" \
      -not -name "build" \
      -not -name "lib" \
      -not -name "instructions" \
      -not -name "tasks" \
      -not -name "outputs" \
      -not -name "bin" \
      -not -name "." \
      -exec rm -rf {} + 2>/dev/null || true && \
    find . -maxdepth 1 -type f \
      -not -name "package.json" \
      -not -name "package-lock.json" \
      -not -name ".env*" \
      -not -name "*.yml" \
      -not -name "*.yaml" \
      -exec rm -f {} + 2>/dev/null || true

# Remove TypeScript source files, source maps, and build artifacts
RUN cd /agent && \
    find . -type f \( -name "*.ts" -o -name "*.tsx" -o -name "*.map" -o -name "tsconfig*.json" \) \
      -delete 2>/dev/null || true

# Obfuscate compiled runtime artifacts generated by build (dist/*.cjs, dist/*.js)
RUN cd /agent && \
    if [ -d dist ]; then \
      find dist -type f \( -name "*.cjs" -o -name "*.js" \) 2>/dev/null | while read file; do \
        if [ -f "$file" ]; then \
          terser "$file" --compress --mangle --toplevel \
            --output "$file.tmp" && \
          mv "$file.tmp" "$file" || true; \
        fi; \
      done; \
    fi

# -----------------------------------------------------------------------------
# 6. BOOTSTRAP: DEFAULT INSTRUCTION FILES
# -----------------------------------------------------------------------------
USER root
RUN find /agent/tasks -mindepth 1 -delete
COPY --chown=agentuser:agentgroup files/bootstrap/test-wikipedia-english.md /agent/tasks/test-wikipedia-english.md
COPY --chown=root:agentgroup files/bootstrap/global-context.json /agent/instructions/global-context.json
COPY --chown=root:agentgroup files/bootstrap/email-permissions.yaml /agent/instructions/email-permissions.yaml
COPY --chown=root:agentgroup files/bootstrap/allowed-domains.yaml /agent/instructions/allowed-domains.yaml

RUN mkdir -p /config-helpers && \
    chown root:root /config-helpers && \
    chmod 550 /config-helpers
COPY --chown=root:root files/bootstrap/extra-local.md /config-helpers/extra-local.md
COPY --chown=root:root files/bootstrap/extra-gemma.md /config-helpers/extra-gemma.md
COPY --chown=root:root files/bootstrap/system-prompt-cn.md /config-helpers/system-prompt-cn.md
COPY --chown=root:root files/bootstrap/system-prompt-default.md /config-helpers/system-prompt-default.md
COPY --chown=root:root files/bootstrap/modes/ /config-helpers/modes/


# =============================================================================
# STAGE 3 – final
# Assembles the runtime image from the two previous stages.
# =============================================================================
FROM system-deps AS final

# Copy the fully-installed agent workspace from the builder stage
COPY --from=agent-builder --chown=agentuser:agentgroup /agent /agent

# -----------------------------------------------------------------------------
# 6. MANAGER SCRIPTS
# -----------------------------------------------------------------------------
USER root

COPY files/scripts/run-qa.sh /usr/local/bin/run-qa
COPY files/scripts/stop-qa.sh /usr/local/bin/stop-qa
COPY files/scripts/playwright-mcp.sh /usr/local/bin/playwright-mcp
COPY files/scripts/email-mcp.sh /usr/local/bin/email-mcp
COPY files/scripts/config-agent.sh /usr/local/bin/config-agent
COPY files/scripts/update-agent-config.sh /usr/local/bin/update-agent-config
COPY files/scripts/run-qa-lib.sh /usr/local/bin/run-qa-lib
COPY files/scripts/check-test-result.sh /usr/local/bin/check-test-result
COPY files/scripts/context-ops-lib.sh /usr/local/bin/context-ops-lib
COPY files/scripts/manage-global-constants.sh /usr/local/bin/manage-global-constants
COPY files/scripts/manage-context-variables.sh /usr/local/bin/manage-context-variables

RUN chown root:root /usr/local/bin/playwright-mcp \
                   /usr/local/bin/email-mcp \
                   /usr/local/bin/run-qa \
                   /usr/local/bin/stop-qa \
                   /usr/local/bin/config-agent \
                   /usr/local/bin/update-agent-config \
                   /usr/local/bin/run-qa-lib \
                   /usr/local/bin/check-test-result \
                   /usr/local/bin/context-ops-lib \
                   /usr/local/bin/manage-global-constants \
                   /usr/local/bin/manage-context-variables && \
    chmod 700 /usr/local/bin/playwright-mcp \
              /usr/local/bin/email-mcp \
              /usr/local/bin/run-qa \
              /usr/local/bin/stop-qa \
              /usr/local/bin/config-agent \
              /usr/local/bin/update-agent-config \
              /usr/local/bin/run-qa-lib \
              /usr/local/bin/check-test-result \
              /usr/local/bin/context-ops-lib \
              /usr/local/bin/manage-global-constants \
              /usr/local/bin/manage-context-variables

# -----------------------------------------------------------------------------
# 7. SUPERVISOR CONFIGURATION
# -----------------------------------------------------------------------------
COPY files/configs/supervisord.conf /etc/supervisor/conf.d/mcp-services.conf

# -----------------------------------------------------------------------------
# 8. RUNTIME ENVIRONMENT (IDLE MODE)
# -----------------------------------------------------------------------------
ENV DISPLAY=:99
ENV PYTHONUNBUFFERED=1

ENTRYPOINT ["/usr/bin/supervisord", "-n", "-c", "/etc/supervisor/supervisord.conf"]