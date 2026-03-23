#!/bin/bash
# Location: /usr/local/bin/email-mcp
echo "📧 Starting Email MCP Service..."

# 1. Handle Java Memory
JVM_OPTS=${JAVA_OPTS:-"-Xmx256m"}

# 2. Check for permissions file in the agent's instructions (Read-Only)
# We default to the classpath if the file doesn't exist.
PERM_FILE="classpath:permissions.yaml"
if [ -f "/agent/instructions/email-permissions.yaml" ]; then
    echo "🔒 Found custom permissions at /agent/instructions/email-permissions.yaml"
    PERM_FILE="file:/agent/instructions/email-permissions.yaml"
fi

# 3. Build the Spring Boot Overrides
# We use the --name=value syntax which overrides application.yaml
SPRING_ARGS=""

if [ -n "$MAIL_HOST" ]; then
    echo "🌐 Using Mail Host: $MAIL_HOST"
    SPRING_ARGS="$SPRING_ARGS --mail-host=$MAIL_HOST"
fi

if [ -n "$MAIL_PORT" ]; then
    echo "🔌 Using Mail Port: $MAIL_PORT"
    SPRING_ARGS="$SPRING_ARGS --mail-port=$MAIL_PORT"
fi

# 4. Execute the JAR
# We combine the fixed config location with our dynamic overrides
java $JVM_OPTS -jar /services/email/email-mcp.jar \
  --spring.config.additional-location=/services/email/email-mcp.properties \
  --permissions-file="$PERM_FILE" \
  $SPRING_ARGS