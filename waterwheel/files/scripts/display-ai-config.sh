#!/usr/bin/env bash
# Location: /usr/local/bin/display-ai-config
# Description: Prints effective AI provider/model and token mode as JSON.
set -euo pipefail

AGENT_PATH="${AGENT_PATH:-/agent}"

usage() {
  cat <<EOF
Usage: display-ai-config [-ap <agent-path>] [help|h|--help|-h]

Options:
  -ap <path>   Override agent path (default: /agent)
  -h, --help   Show this help message
  h, help      Show this help message

Output:
  JSON object with keys: aiProvider, aiModel, tokenMode

Lookup order for values:
  1) Environment variable
  2) Default value in \$AGENT_PATH/config/agent-config.json

Mapping for tokenMode:
  CONTEXT_COMPRESSION=false (case-insensitive) -> default
  CONTEXT_COMPRESSION=other non-empty value       -> efficiency
  no resolved CONTEXT_COMPRESSION value           -> ""
EOF
}

while [[ $# -gt 0 ]]; do
  case "${1:-}" in
    -ap)
      AGENT_PATH="${2:? -ap requires a value}"
      shift 2
      ;;
    -h|--help|h|help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

CONFIG_FILE="${AGENT_PATH}/config/agent-config.json"

get_config_default() {
  local key="$1"

  if [[ ! -f "$CONFIG_FILE" ]]; then
    printf ''
    return 0
  fi

  jq -r --arg k "$key" '
    (."env-params" // [])
    | map(select(.name == $k))
    | .[0].default // ""
  ' "$CONFIG_FILE" 2>/dev/null || printf ''
}

resolve_value() {
  local key="$1"
  local env_value="${!key-}"

  if [[ -n "$env_value" ]]; then
    printf '%s' "$env_value"
  else
    get_config_default "$key"
  fi
}

ai_provider="$(resolve_value "AI_PROVIDER")"
ai_model="$(resolve_value "AI_MODEL")"
context_compression="$(resolve_value "CONTEXT_COMPRESSION")"

token_mode=""
if [[ -n "$context_compression" ]]; then
  context_compression_lower="$(printf '%s' "$context_compression" | tr '[:upper:]' '[:lower:]')"
  if [[ "$context_compression_lower" == "false" ]]; then
    token_mode="default"
  else
    token_mode="efficiency"
  fi
fi

jq -n \
  --arg aiProvider "$ai_provider" \
  --arg aiModel "$ai_model" \
  --arg tokenMode "$token_mode" \
  '{aiProvider: $aiProvider, aiModel: $aiModel, tokenMode: $tokenMode}'

