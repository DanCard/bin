#!/bin/bash
# Compare ROCm vs Vulkan real-world MTP perf on the local Qwen3 27B model.
# Uses the same flags as ~/bin/summarize so numbers are representative.
set -u

MODEL="${MODEL:-/home/dcar/llms/qwen3/6/mtp-27B-UD-Q8_K_XL.gguf}"
LLAMA_CLI="${LLAMA_CLI:-/home/dcar/github/llama.cpp/build/bin/llama-cli}"
PROMPT="${PROMPT:-Explain the etymological origin of the English word 'pot' in detail. Trace its Proto-Germanic and Latin roots, compare it to the word 'kettle', and describe how cooking-vessel vocabulary evolved across Old English, Middle English, and Modern English. Include examples of cognate words in other Germanic languages.}"
MAX_TOKENS="${MAX_TOKENS:-256}"
REPS="${REPS:-1}"
SEED="${SEED:-42}"
DEVICES=("ROCm0" "Vulkan0")
LOG_DIR="${LOG_DIR:-/tmp}"

COMMON=(
    --spec-type draft-mtp
    --spec-draft-n-max 3
    -ngl 999
    -c 65536
    -fa off
    -ctk q8_0
    -ctv q8_0
    --temp 0
    --seed "$SEED"
    --perf
    --no-display-prompt
    --simple-io
    -n "$MAX_TOKENS"
    -p "$PROMPT"
)

if [[ ! -x "$LLAMA_CLI" ]]; then
    echo "error: llama-cli not found or not executable: $LLAMA_CLI" >&2
    exit 1
fi
if [[ ! -f "$MODEL" ]]; then
    echo "error: model not found: $MODEL" >&2
    exit 1
fi

# parse_perf <log-file>  -> prints "pp_tps tg_tps total_ms" (or "NA NA NA")
parse_perf() {
    local log="$1"
    awk '
        /prompt eval time =/ {
            # line: ... prompt eval time = N ms / N tokens (N ms per token, N tokens per second)
            for (i = 1; i <= NF; i++) if ($i == "tokens" && $(i+1) == "per") { pp = $(i-1); break }
        }
        /^[^p]*[[:space:]]eval time =/ {
            # the generation eval line (does not start with "prompt"); same suffix
            for (i = 1; i <= NF; i++) if ($i == "tokens" && $(i+1) == "per") { tg = $(i-1); break }
        }
        /total time =/ {
            for (i = 1; i <= NF; i++) if ($i == "=") { total = $(i+1); break }
        }
        END {
            if (pp == "")    pp = "NA"
            if (tg == "")    tg = "NA"
            if (total == "") total = "NA"
            printf "%s %s %s\n", pp, tg, total
        }
    ' "$log"
}

# median <numbers...>
median() {
    printf '%s\n' "$@" | awk '
        { a[NR] = $1 + 0 }
        END {
            n = NR
            if (n == 0) { print "NA"; exit }
            # insertion sort
            for (i = 2; i <= n; i++) {
                v = a[i]; j = i - 1
                while (j >= 1 && a[j] > v) { a[j+1] = a[j]; j-- }
                a[j+1] = v
            }
            if (n % 2) printf "%.2f", a[(n+1)/2]
            else       printf "%.2f", (a[n/2] + a[n/2+1]) / 2
        }
    '
}

declare -A MEDIAN_PP MEDIAN_TG MEDIAN_TOTAL

echo "Model:      $MODEL"
echo "Binary:     $LLAMA_CLI"
echo "Max tokens: $MAX_TOKENS   Reps: $REPS   Seed: $SEED"
echo "Devices:    ${DEVICES[*]}"
echo

for dev in "${DEVICES[@]}"; do
    pp_vals=()
    tg_vals=()
    total_vals=()
    for r in $(seq 1 "$REPS"); do
        log="${LOG_DIR}/compare_llm_perf_${dev}_${r}.log"
        printf '  [%s rep %d/%d] running...' "$dev" "$r" "$REPS"
        if ! "$LLAMA_CLI" -m "$MODEL" --device "$dev" "${COMMON[@]}" >"$log" 2>&1; then
            echo " FAILED (see $log)"
            continue
        fi
        read -r pp tg total < <(parse_perf "$log")
        printf ' pp=%s tg=%s total_ms=%s  log=%s\n' "$pp" "$tg" "$total" "$log"
        [[ "$pp"    != "NA" ]] && pp_vals+=("$pp")
        [[ "$tg"    != "NA" ]] && tg_vals+=("$tg")
        [[ "$total" != "NA" ]] && total_vals+=("$total")
    done
    MEDIAN_PP[$dev]=$([[ ${#pp_vals[@]}    -gt 0 ]] && median "${pp_vals[@]}"    || echo "NA")
    MEDIAN_TG[$dev]=$([[ ${#tg_vals[@]}    -gt 0 ]] && median "${tg_vals[@]}"    || echo "NA")
    MEDIAN_TOTAL[$dev]=$([[ ${#total_vals[@]} -gt 0 ]] && median "${total_vals[@]}" || echo "NA")
done

echo
echo "## Results (median of $REPS reps)"
echo
printf '| %-8s | %-12s | %-12s | %-14s |\n' "Backend" "PP tok/s" "TG tok/s" "Total time ms"
printf '| %-8s | %-12s | %-12s | %-14s |\n' "--------" "------------" "------------" "--------------"
for dev in "${DEVICES[@]}"; do
    printf '| %-8s | %-12s | %-12s | %-14s |\n' \
        "$dev" "${MEDIAN_PP[$dev]}" "${MEDIAN_TG[$dev]}" "${MEDIAN_TOTAL[$dev]}"
done
