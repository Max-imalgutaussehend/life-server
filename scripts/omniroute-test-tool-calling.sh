#!/usr/bin/env bash
# =============================================================================
# omniroute-test-tool-calling.sh — does a given omniroute model support tools?
# =============================================================================
#
# WHY THIS EXISTS
#   ADR-0026 measured that the free provider pool cannot serve agent work
#   ("400 No target in combo auto supports tool calling"). On 2026-09-13 that
#   claim was disputed and re-tested directly against the three providers
#   still enabled in the `free-first` combo (cohere, zai, mistral) — see the
#   comment block in omniroute-providers.sh. All three returned 429 (quota /
#   balance / rate-limit exhausted by free-first's own live traffic), so nothing
#   was confirmed either way. Kept as a script, not a one-off, because the
#   right moment to re-test is unpredictable (whenever one of the three has
#   quota again) and the shape of a real tool-calling request is easy to get
#   subtly wrong (empty tools array, wrong field name) if retyped from memory.
#
# USAGE
#   ./scripts/omniroute-test-tool-calling.sh <model-id>
#   ./scripts/omniroute-test-tool-calling.sh cohere/command-a-03-2025
#   ./scripts/omniroute-test-tool-calling.sh zai/glm-5-turbo
#   ./scripts/omniroute-test-tool-calling.sh mistral/mistral-small-latest
#
# HOW TO READ THE RESULT
#   - A response containing "tool_calls" (or "type":"tool_use" for an
#     Anthropic-shaped model) means the model called the tool: tool calling
#     works for this model through this router.
#   - A 4xx whose message mentions "tool"/"function calling" and the word
#     "support" (not quota/balance/rate-limit) means it genuinely doesn't.
#   - Any other error (429, 5xx, timeout) means the test is inconclusive —
#     the request never reached model inference. Re-run later; do not treat
#     this as a "no".
#
# It talks to the container over docker exec on the server, so it needs the
# same SSH access deploy.sh uses.
# =============================================================================
set -euo pipefail

MODEL="${1:?usage: omniroute-test-tool-calling.sh <model-id>}"
SSH_KEY="${SSH_KEY:-$HOME/.ssh/life-server}"
SERVER="${SERVER:?set SERVER=deploy@<host-ip>}"

# No local .env check: unlike deploy.sh, this reads OMNIROUTE_API_KEY from the
# server's own .env over SSH and never touches a local copy.
SSH_CTL="$HOME/.ssh/ls-deploy-%r@%h:%p"
SSH_OPTS=(-i "$SSH_KEY" -o BatchMode=yes
	-o ControlMaster=auto -o ControlPath="$SSH_CTL" -o ControlPersist=120)

ssh "${SSH_OPTS[@]}" "$SERVER" MODEL="$MODEL" 'bash -s' <<'REMOTE'
set -euo pipefail
export MODEL
CLAW_KEY="$(grep -E '^OMNIROUTE_API_KEY=' /opt/life-server/.env | cut -d= -f2-)"

cat > /tmp/omniroute-tool-test-inner.sh <<'INNER'
set -eu
apk add -q --no-cache curl
B=http://127.0.0.1:20128
CLAW_KEY="$1"
MODEL="$2"

cat > /tmp/toolreq.json <<EOF
{
  "model": "$MODEL",
  "max_tokens": 100,
  "messages": [{"role": "user", "content": "What is the weather in Berlin? Use the get_weather tool."}],
  "tools": [
    {
      "type": "function",
      "function": {
        "name": "get_weather",
        "description": "Get the current weather for a location",
        "parameters": {
          "type": "object",
          "properties": {"location": {"type": "string", "description": "City name"}},
          "required": ["location"]
        }
      }
    }
  ]
}
EOF

echo "=== testing tool-calling on $MODEL ==="
curl -sS --max-time 30 -w '\nHTTP_STATUS=%{http_code}\n' -X POST \
  -H "Authorization: Bearer $CLAW_KEY" -H 'Content-Type: application/json' \
  --data-binary @/tmp/toolreq.json "$B/v1/chat/completions"
echo
INNER

docker run --rm --network container:prod-omniroute \
	-v /tmp/omniroute-tool-test-inner.sh:/t.sh:ro \
	alpine:3.21 sh /t.sh "$CLAW_KEY" "$MODEL"
rm -f /tmp/omniroute-tool-test-inner.sh
REMOTE
