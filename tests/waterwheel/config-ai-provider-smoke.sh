#!/usr/bin/env bash
set -euo pipefail

repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cap="$repo/waterwheel/files/scripts/config-ai-provider.sh"
template="$repo/waterwheel/files/bootstrap/default-agent-config.json"
modes="$repo/waterwheel/files/bootstrap/modes"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

# Builds a fresh agent/helpers pair under $tmpdir/<name> and echoes the agent path.
new_env() {
  local name="$1"
  local root="$tmpdir/$name"
  rm -rf "$root"
  mkdir -p "$root/agent/config" "$root/agent/instructions" "$root/helpers"
  cp "$template" "$root/helpers/default-agent-config.json"
  cp -r "$modes" "$root/helpers/modes"
  printf '%s' "$root"
}

# Reads an env-param default out of a written agent-config.json.
param() {
  jq -r --arg k "$2" '(."env-params" // []) | map(select(.name == $k)) | .[0].default // ""' \
    "$1/agent/config/agent-config.json"
}

echo '== every provider default mode writes its own AI_PROVIDER =='
# Regression guard for mode files whose last line was dropped when the file had
# no trailing newline: gemini and deepseek silently fell back to anthropic.
for prov in anthropic deepseek gemini openai; do
  root="$(new_env "prov-$prov")"
  bash "$cap" --provider "$prov" --model test-model --mode default \
    -ap "$root/agent" -cp "$root/helpers" >/dev/null
  got="$(param "$root" AI_PROVIDER)"
  if [ "$got" != "$prov" ]; then
    echo "expected AI_PROVIDER=$prov, got '$got'" >&2
    exit 1
  fi
done

echo '== gemma default mode applies its last line (MAXIMUM_RESTRICTED_TOOL_USAGE=5) =='
root="$(new_env gemma)"
bash "$cap" --provider gemma --model gemma4:e4b --mode default \
  --base-url http://host.docker.internal:11434 -ap "$root/agent" -cp "$root/helpers" >/dev/null
if [ "$(param "$root" MAXIMUM_RESTRICTED_TOOL_USAGE)" != "5" ]; then
  echo "expected MAXIMUM_RESTRICTED_TOOL_USAGE=5 from gemma-default.env" >&2
  exit 1
fi
if [ "$(param "$root" AI_BASE_URL)" != "http://host.docker.internal:11434" ]; then
  echo 'expected --base-url to be honored for gemma' >&2
  exit 1
fi

echo '== openai-compatible without --base-url fails and writes nothing =='
root="$(new_env no-base-url)"
if bash "$cap" --provider openai-compatible --model some/model --mode default \
  -ap "$root/agent" -cp "$root/helpers" >/dev/null 2>&1; then
  echo 'expected failure when --base-url is missing' >&2
  exit 1
fi
if [ -f "$root/agent/config/agent-config.json" ]; then
  echo 'expected no config written when validation fails' >&2
  exit 1
fi

echo '== openai-compatible writes all four optional values =='
root="$(new_env full)"
bash "$cap" --provider openai-compatible --model qwen/qwen3-235b-a22b --mode efficiency \
  --base-url https://openrouter.ai/api/v1 \
  --extra-headers '{"HTTP-Referer":"https://duotail.com"}' \
  --temperature 0.2 --temperature-enabled FALSE \
  -ap "$root/agent" -cp "$root/helpers" >/dev/null 2>&1
[ "$(param "$root" AI_PROVIDER)" = "openai-compatible" ] || { echo 'bad AI_PROVIDER' >&2; exit 1; }
[ "$(param "$root" AI_BASE_URL)" = "https://openrouter.ai/api/v1" ] || { echo 'bad AI_BASE_URL' >&2; exit 1; }
[ "$(param "$root" AI_TEMPERATURE)" = "0.2" ] || { echo 'bad AI_TEMPERATURE' >&2; exit 1; }
# --temperature-enabled is lowercased before being written.
[ "$(param "$root" AI_TEMPERATURE_ENABLED)" = "false" ] || { echo 'bad AI_TEMPERATURE_ENABLED' >&2; exit 1; }
[ "$(param "$root" AI_EXTRA_HEADERS)" = '{"HTTP-Referer":"https://duotail.com"}' ] \
  || { echo 'bad AI_EXTRA_HEADERS' >&2; exit 1; }

echo '== malformed --extra-headers is rejected without echoing the value =='
secret='{"Authorization":'
for bad in "$secret" '["a","b"]' '{"X-Count":3}'; do
  root="$(new_env "hdr-$RANDOM")"
  out="$(bash "$cap" --provider openai-compatible --model some/model --mode default \
    --base-url https://example.com/v1 --extra-headers "$bad" \
    -ap "$root/agent" -cp "$root/helpers" 2>&1 || true)"
  if [ -f "$root/agent/config/agent-config.json" ]; then
    echo "expected no config written for malformed --extra-headers: $bad" >&2
    exit 1
  fi
  # The value is sensitive -- it must never appear in stdout or stderr.
  if printf '%s' "$out" | grep -qF "$bad"; then
    echo 'rejected --extra-headers value leaked into output' >&2
    exit 1
  fi
done

echo '== the sensitive value is not echoed on success either =='
root="$(new_env no-echo)"
out="$(bash "$cap" --provider openai-compatible --model some/model --mode default \
  --base-url https://example.com/v1 --extra-headers '{"Authorization":"Bearer sk-secret"}' \
  -ap "$root/agent" -cp "$root/helpers" 2>&1)"
if printf '%s' "$out" | grep -q 'sk-secret'; then
  echo 'AI_EXTRA_HEADERS value leaked into the applied-settings summary' >&2
  exit 1
fi
printf '%s' "$out" | grep -q 'AI_EXTRA_HEADERS=<set>' \
  || { echo 'expected masked AI_EXTRA_HEADERS=<set> line' >&2; exit 1; }

echo '== bad --temperature and --temperature-enabled are rejected =='
root="$(new_env bad-scalars)"
if bash "$cap" --provider openai-compatible --model m --mode default \
  --base-url https://example.com/v1 --temperature hot \
  -ap "$root/agent" -cp "$root/helpers" >/dev/null 2>&1; then
  echo 'expected non-numeric --temperature to be rejected' >&2
  exit 1
fi
if bash "$cap" --provider openai-compatible --model m --mode default \
  --base-url https://example.com/v1 --temperature-enabled maybe \
  -ap "$root/agent" -cp "$root/helpers" >/dev/null 2>&1; then
  echo 'expected non-boolean --temperature-enabled to be rejected' >&2
  exit 1
fi

echo '== flags ignored by a provider warn but still succeed =='
root="$(new_env ignored)"
err="$(bash "$cap" --provider anthropic --model claude-sonnet-4-6 --mode default \
  --extra-headers '{"X-Title":"waterwheel"}' \
  -ap "$root/agent" -cp "$root/helpers" 2>&1 >/dev/null)"
printf '%s' "$err" | grep -q 'ignored by provider' \
  || { echo 'expected an ignored-flag warning' >&2; exit 1; }
[ "$(param "$root" AI_PROVIDER)" = "anthropic" ] || { echo 'expected config still written' >&2; exit 1; }

echo '== provider locking still blocks openai <-> openai-compatible =='
root="$(new_env locking)"
bash "$cap" --provider openai --model gpt-5.4 --mode default \
  -ap "$root/agent" -cp "$root/helpers" >/dev/null
if bash "$cap" --provider openai-compatible --model some/model --mode default \
  --base-url https://example.com/v1 -ap "$root/agent" -cp "$root/helpers" >/dev/null 2>&1; then
  echo 'expected openai -> openai-compatible switch to be blocked' >&2
  exit 1
fi
root="$(new_env locking2)"
bash "$cap" --provider openai-compatible --model some/model --mode default \
  --base-url https://example.com/v1 -ap "$root/agent" -cp "$root/helpers" >/dev/null
if bash "$cap" --provider openai --model gpt-5.4 --mode default \
  -ap "$root/agent" -cp "$root/helpers" >/dev/null 2>&1; then
  echo 'expected openai-compatible -> openai switch to be blocked' >&2
  exit 1
fi

echo '== switching modes within openai-compatible is allowed =='
bash "$cap" --provider openai-compatible --model some/model --mode efficiency \
  --base-url https://example.com/v1 -ap "$root/agent" -cp "$root/helpers" >/dev/null
[ "$(param "$root" CONTEXT_COMPRESSION)" = "true" ] \
  || { echo 'expected efficiency mode to enable CONTEXT_COMPRESSION' >&2; exit 1; }

echo 'config-ai-provider smoke: OK'
