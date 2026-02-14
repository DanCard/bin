#!/bin/bash

# Generate detailed meeting notes from a transcription using local llama-server
# Usage: summarize.sh <transcript.txt> [output.md]

LLAMA_URL="${LLAMA_URL:-http://localhost:8080}"
MAX_TOKENS="${MAX_TOKENS:-8192}"

if [ -z "$1" ]; then
    echo "Usage: summarize.sh <transcript.txt> [output.md]"
    echo "  If output.md is not given, prints to stdout."
    echo ""
    echo "Environment variables:"
    echo "  LLAMA_URL    - llama-server URL (default: http://localhost:8080)"
    echo "  MAX_TOKENS   - max output tokens (default: 8192)"
    exit 1
fi

TRANSCRIPT="$1"
OUTPUT="$2"

if [ ! -f "$TRANSCRIPT" ]; then
    echo "ERROR: File not found: $TRANSCRIPT"
    exit 1
fi

# Verify server is reachable
if ! curl -sf "${LLAMA_URL}/v1/models" >/dev/null 2>&1; then
    echo "ERROR: llama-server not reachable at ${LLAMA_URL}"
    exit 1
fi

SYSTEM_PROMPT="You are a meeting notes assistant. Produce detailed, thorough meeting notes — not a concise summary. Include all topics discussed, decisions made, action items, who said what, and any context or nuance mentioned. Use markdown formatting with headers and bullet points.  Include quotes and excerpts."

USER_PROMPT="Here is the full transcript of a meeting. Write detailed meeting notes covering every topic, decision, action item, and important details discussed.  Include interesting quotes and key excerpts."

generate() {
    jq -n \
        --rawfile transcript "$TRANSCRIPT" \
        --arg system "$SYSTEM_PROMPT" \
        --arg user "$USER_PROMPT" \
        --argjson max_tokens "$MAX_TOKENS" \
        '{
          model: "qwen3",
          messages: [
            {role: "system", content: $system},
            {role: "user", content: ($user + "\n\n" + $transcript)}
          ],
          max_tokens: $max_tokens,
          temperature: 0,
          stream: true
        }' | curl -sN "${LLAMA_URL}/v1/chat/completions" \
      -H "Content-Type: application/json" \
      -d @- | sed -u 's/^data: //' | while read -r line; do
        [ "$line" = "[DONE]" ] && break
        printf '%s' "$(echo "$line" | jq -r '.choices[0].delta.content // empty' 2>/dev/null)"
    done
    echo
}

if [ -n "$OUTPUT" ]; then
    echo "Generating meeting notes → $OUTPUT"
    generate | tee "$OUTPUT"
    echo ""
    echo "Saved to: $OUTPUT"
else
    generate
fi
