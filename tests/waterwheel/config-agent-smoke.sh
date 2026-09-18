#!/usr/bin/env bash
set -euo pipefail

# Covers the openai-compatible prompt block in config_ai_mode. config-agent is
# interactive, but it reads plain stdin, so the prompts can be driven directly.
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
agent="$repo/waterwheel/files/scripts/config-agent.sh"
template="$repo/waterwheel/files/bootstrap/default-agent-config.json"
bootstrap="$repo/waterwheel/files/bootstrap"
tmpdir=$(mktemp -d)

cleanup() {
  rm -rf "$tmpdir"
}
trap cleanup EXIT

# Menu position of "OpenAI-Compatible Default Mode". Modes are listed in glob
# order, so derive it rather than hardcoding a number that a new mode shifts.
oc_choice="$(ls "$bootstrap/modes"/*.env | grep -n 'openai-compatible-default\.env$' | cut -d: -f1)"
[ -n "$oc_choice" ] || { echo 'could not locate the openai-compatible mode in the menu' >&2; exit 1; }

new_env() {
  local root="$tmpdir/$1"
  rm -rf "$root"
  mkdir -p "$root/agent/config" "$root/agent/instructions" "$root/helpers"
  cp "$template" "$root/helpers/default-agent-config.json"
  cp -r "$bootstrap/modes" "$root/helpers/modes"
  cp "$bootstrap/extra-gemma.md" "$bootstrap/extra-local.md" "$root/helpers/"
  printf '%s' "$root"
}

param() {
  jq -r --arg k "$2" '(."env-params" // []) | map(select(.name == $k)) | .[0].default // ""' \
    "$1/agent/config/agent-config.json"
}

echo '== the temperature prompt accepts y/yes/n/no and blank =='
# Regression guard: `^[Nn]$` silently discarded "no" and left the template's
# true, with nothing in the summary to signal it.
for pair in "n:false" "no:false" "NO:false" "y:true" "yes:true" ":true"; do
  ans="${pair%%:*}"
  want="${pair##*:}"
  root="$(new_env "temp-${ans:-blank}")"
  printf "%s\nm\nhttps://x.com/v1\n\n%s\ny\n0\n" "$oc_choice" "$ans" \
    | bash "$agent" -ap "$root/agent" -cp "$root/helpers" >/dev/null 2>&1
  got="$(param "$root" AI_TEMPERATURE_ENABLED)"
  if [ "$got" != "$want" ]; then
    echo "answer '$ans' should give AI_TEMPERATURE_ENABLED=$want, got '$got'" >&2
    exit 1
  fi
done

echo '== an unrecognized temperature answer re-prompts instead of defaulting =='
# A typo must not be read as agreement: silently defaulting would enable
# temperature against an endpoint the user was trying to opt out of.
root="$(new_env temp-typo)"
out="$(printf "%s\nm\nhttps://x.com/v1\n\nnah\nn\ny\n0\n" "$oc_choice" \
  | bash "$agent" -ap "$root/agent" -cp "$root/helpers" 2>&1)"
[ "$(param "$root" AI_TEMPERATURE_ENABLED)" = "false" ] \
  || { echo 'a typo was swallowed instead of re-prompted' >&2; exit 1; }
printf '%s' "$out" | grep -q 'Please answer y or n' \
  || { echo 'expected a re-prompt message for an unrecognized answer' >&2; exit 1; }
# The chosen value must always be visible in the summary.
printf '%s' "$out" | grep -q 'AI_TEMPERATURE_ENABLED=false' \
  || { echo 'expected the applied value in the summary' >&2; exit 1; }

echo '== a blank base URL re-prompts, and the URL is shape-checked =='
root="$(new_env url)"
out="$(printf "%s\nm\n\nnot-a-url\nhttps://api.x.com/ v1\n  https://openrouter.ai/api/v1/  \n\ny\ny\n0\n" "$oc_choice" \
  | bash "$agent" -ap "$root/agent" -cp "$root/helpers" 2>&1)"
printf '%s' "$out" | grep -q 'A base URL is required' || { echo 'expected a blank re-prompt' >&2; exit 1; }
printf '%s' "$out" | grep -q 'Must start with http' || { echo 'expected a scheme re-prompt' >&2; exit 1; }
printf '%s' "$out" | grep -q 'Must not contain whitespace' || { echo 'expected a whitespace re-prompt' >&2; exit 1; }
# Trimmed and de-slashed: the agent appends /chat/completions verbatim.
[ "$(param "$root" AI_BASE_URL)" = "https://openrouter.ai/api/v1" ] \
  || { echo "base URL not normalized, got '$(param "$root" AI_BASE_URL)'" >&2; exit 1; }

echo '== headers: malformed re-prompts, blank keeps, none clears =='
root="$(new_env headers)"
out="$(printf "%s\nm\nhttps://x.com/v1\ngarbage\n{\"X-Title\":\"ww\"}\nn\ny\n0\n" "$oc_choice" \
  | bash "$agent" -ap "$root/agent" -cp "$root/helpers" 2>&1)"
printf '%s' "$out" | grep -q 'Must be a JSON object' || { echo 'expected a header re-prompt' >&2; exit 1; }
# Sensitive: the rejected value must not be echoed back.
printf '%s' "$out" | grep -q 'garbage' && { echo 'rejected header value was echoed' >&2; exit 1; }
[ "$(param "$root" AI_EXTRA_HEADERS)" = '{"X-Title":"ww"}' ] || { echo 'headers not applied' >&2; exit 1; }

# Blank at the headers prompt must keep the existing value across a mode switch.
printf "1\n2\nm\nhttps://x.com/v1\n\n\ny\n0\n0\n" \
  | bash "$agent" -ap "$root/agent" -cp "$root/helpers" >/dev/null 2>&1
[ "$(param "$root" AI_EXTRA_HEADERS)" = '{"X-Title":"ww"}' ] \
  || { echo 'a mode switch wiped AI_EXTRA_HEADERS' >&2; exit 1; }
[ "$(param "$root" AI_TEMPERATURE_ENABLED)" = "false" ] \
  || { echo 'a mode switch wiped AI_TEMPERATURE_ENABLED' >&2; exit 1; }

# "none" clears it.
printf "1\n1\nm\nhttps://x.com/v1\nnone\ny\ny\n0\n0\n" \
  | bash "$agent" -ap "$root/agent" -cp "$root/helpers" >/dev/null 2>&1
[ "$(param "$root" AI_EXTRA_HEADERS)" = "" ] || { echo "'none' did not clear the headers" >&2; exit 1; }

echo '== providers other than gemma/openai-compatible get no extra prompts =='
root="$(new_env anthropic)"
printf "1\nclaude-sonnet-4-6\ny\n0\n" | bash "$agent" -ap "$root/agent" -cp "$root/helpers" >/dev/null 2>&1
[ "$(param "$root" AI_PROVIDER)" = "anthropic" ] || { echo 'anthropic path regressed' >&2; exit 1; }
[ "$(param "$root" AI_BASE_URL)" = "" ] || { echo 'unexpected AI_BASE_URL for anthropic' >&2; exit 1; }

echo 'config-agent smoke: OK'
