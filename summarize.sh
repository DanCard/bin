#!/bin/bash
# summarize.sh - Generate structured meeting notes using local LLM
#
# WHAT THIS DOES:
#   Takes a text transcript (e.g., from transcribe.py) and sends it to a
#   locally running llama-server to generate a structured summary.
#
# HOW IT WORKS:
#   1. Reads the transcript file.
#   2. Constructs a prompt asking for:
#      - Meeting Title & Date
#      - Key Participants
#      - Main Discussion Points
#      - Action Items & Decisions
#   3. Calls the llama-server API (default: localhost:8080).
#   4. Outputs Markdown to a file or stdout.
#
# USAGE:
#   summarize.sh transcript.txt [summary.md]
#
# REQUIRES: 
#   - llama-server (running with a model like Llama-3 or Mistral)
#   - curl, jq

LLAMA_URL="${LLAMA_URL:-http://localhost:8080}"
MAX_TOKENS="${MAX_TOKENS:-8192}"

if [ -z "$1" ]; then
    echo "Usage: $0 <transcript.txt> [output.md]"
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
