#!/bin/bash

# Configuration
MODEL="/home/dcar/llms/qwen3/6/mtp-27B-UD-Q8_K_XL.gguf"
LLAMA_BENCH="/home/dcar/github/llama.cpp/build/bin/llama-bench"
LLAMA_CLI="/home/dcar/github/llama.cpp/build/bin/llama-cli"
PROMPT="origin of the word pot , similar to the word kettle"
COMMON_ARGS="--spec-type draft-mtp --spec-draft-n-max 3 -ngl 999 -c 256000 -fa on -ctk q8_0 -ctv q8_0 --no-mmap --temp 0"

# Colors for output
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}=== LLM Performance Comparison: ROCm vs Vulkan ===${NC}"
echo "Model: $MODEL"

# 1. Raw Benchmarking (Throughput)
echo -e "\n${GREEN}--- Phase 1: Raw Throughput (llama-bench) ---${NC}"

echo -e "\n[Testing ROCm]"
$LLAMA_BENCH -m "$MODEL" -p 512 -n 128 --device rocm0 2>/dev/null | grep -E "test|t/s"

echo -e "\n[Testing Vulkan]"
$LLAMA_BENCH -m "$MODEL" -p 512 -n 128 --device vulkan0 2>/dev/null | grep -E "test|t/s"

# 2. Real-world Test (CLI)
echo -e "\n${GREEN}--- Phase 2: Real-world Prompt (llama-cli) ---${NC}"

echo -e "\n[Testing ROCm]"
time $LLAMA_CLI -m "$MODEL" $COMMON_ARGS --device rocm0 -p "$PROMPT" -n 128 2>&1 | grep -E "eval time|throughput"

echo -e "\n[Testing Vulkan]"
time $LLAMA_CLI -m "$MODEL" $COMMON_ARGS --device vulkan0 -p "$PROMPT" -n 128 2>&1 | grep -E "eval time|throughput"

echo -e "\n${BLUE}=== Comparison Complete ===${NC}"
