#!/usr/bin/env bash
set -euo pipefail

DATASET_NAME="${DATASET_NAME:-princeton-nlp/SWE-bench_Verified}"
SPLIT="${SPLIT:-test}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SWE_PLAY_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SWE_BENCH_DIR="$ROOT_DIR/SWE-bench"
BASELINE_DIR="$ROOT_DIR/baseline-runs"
PROMPT_FILE="${PROMPT_FILE:-$SCRIPT_DIR/codex_baseline_prompt.md}"
MODEL="${MODEL:-}"
COST_MODEL="${COST_MODEL:-${MODEL:-gpt-5.5}}"
START_INDEX="${START_INDEX:-0}"
EVALUATE="${EVALUATE:-1}"
DRY_RUN="${DRY_RUN:-0}"

usage() {
  cat <<'EOF'
Usage:
  scripts/run_codex_baseline.sh COUNT

Environment variables:
  DATASET_NAME   Default: princeton-nlp/SWE-bench_Verified
  SPLIT          Default: test
  START_INDEX    Dataset index to start from. Default: 0
  EVALUATE       Run SWE-bench harness after each Codex attempt. Default: 1
  MODEL          Optional Codex model override
  COST_MODEL     Model name used for cost estimate. Default: MODEL or gpt-5.5
  PROMPT_FILE    Optional prompt file. Default: scripts/codex_baseline_prompt.md
  SWE_PLAY_ROOT  Optional project root override
  DRY_RUN        Print selected instance IDs and exit. Default: 0

Cost estimate overrides:
  CODEX_INPUT_USD_PER_1M
  CODEX_CACHED_INPUT_USD_PER_1M
  CODEX_OUTPUT_USD_PER_1M

Example:
  scripts/run_codex_baseline.sh 5
  START_INDEX=20 EVALUATE=0 scripts/run_codex_baseline.sh 10
  DRY_RUN=1 scripts/run_codex_baseline.sh 5
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

COUNT="${1:-}"
if [[ -z "$COUNT" || ! "$COUNT" =~ ^[0-9]+$ || "$COUNT" -lt 1 ]]; then
  echo "ERROR: COUNT must be a positive integer." >&2
  usage >&2
  exit 2
fi

if [[ ! "$START_INDEX" =~ ^[0-9]+$ ]]; then
  echo "ERROR: START_INDEX must be a non-negative integer." >&2
  exit 2
fi

if [[ ! -f "$PROMPT_FILE" ]]; then
  echo "ERROR: prompt file not found: $PROMPT_FILE" >&2
  exit 2
fi

if [[ ! -d "$SWE_BENCH_DIR/.venv" ]]; then
  echo "ERROR: SWE-bench venv not found at $SWE_BENCH_DIR/.venv" >&2
  exit 2
fi

if ! command -v codex >/dev/null 2>&1; then
  echo "ERROR: codex CLI not found in PATH." >&2
  exit 2
fi

source "$SWE_BENCH_DIR/.venv/bin/activate"
mkdir -p "$BASELINE_DIR"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
run_dir="$BASELINE_DIR/codex_${timestamp}"
auto_instances_dir="$run_dir/instances"
mkdir -p "$run_dir"
mkdir -p "$auto_instances_dir"

ids_file="$run_dir/instance_ids.txt"
summary_file="$run_dir/summary.tsv"

DATASET_NAME="$DATASET_NAME" SPLIT="$SPLIT" START_INDEX="$START_INDEX" COUNT="$COUNT" python - <<'PY' > "$ids_file"
import os
import sys

from datasets import load_dataset

dataset_name = os.environ["DATASET_NAME"]
split = os.environ["SPLIT"]
start = int(os.environ["START_INDEX"])
count = int(os.environ["COUNT"])

dataset = load_dataset(dataset_name, split=split)
end = min(start + count, len(dataset))
if start >= len(dataset):
    print(
        f"ERROR: START_INDEX {start} is outside dataset length {len(dataset)}",
        file=sys.stderr,
    )
    sys.exit(1)

for index in range(start, end):
    print(dataset[index]["instance_id"])
PY

printf "instance_id\tcodex_status\teval_status\tresolved\tcodex_seconds\tcodex_input_tokens\tcodex_cached_input_tokens\tcodex_output_tokens\tcodex_reasoning_output_tokens\tcodex_cost_estimate_usd\tcodex_cost_method\tinstance_dir\tcodex_log\teval_log\n" > "$summary_file"

echo "Automatic baseline run started."
echo "Dataset: $DATASET_NAME"
echo "Split: $SPLIT"
echo "Start index: $START_INDEX"
echo "Count requested: $COUNT"
echo "Run directory: $run_dir"
echo

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN=1; selected instance IDs:"
  cat "$ids_file"
  echo
  echo "No setup, Codex execution, or evaluation was run."
  exit 0
fi

while IFS= read -r instance_id; do
  [[ -n "$instance_id" ]] || continue

  instance_dir="$auto_instances_dir/$instance_id"
  instance_run_dir="$run_dir/$instance_id"
  mkdir -p "$instance_run_dir"
  codex_log="$instance_run_dir/codex.log"
  codex_final="$instance_run_dir/codex_final.md"
  codex_usage="$instance_run_dir/codex_usage.json"
  setup_log="$instance_run_dir/setup.log"
  eval_log="$instance_run_dir/eval.log"
  patch_file="$instance_run_dir/model.patch"
  codex_seconds=""
  input_tokens="0"
  cached_input_tokens="0"
  output_tokens="0"
  reasoning_output_tokens="0"
  cost_estimate_usd=""
  cost_method="not_measured"

  echo "==> $instance_id: setup"
  if ! INSTANCE_ID="$instance_id" DATASET_NAME="$DATASET_NAME" SPLIT="$SPLIT" INSTANCES_DIR="$auto_instances_dir" "$SCRIPT_DIR/setup_instance.sh" >"$setup_log" 2>&1; then
    printf "%s\tsetup_failed\tnot_run\tunknown\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$instance_id" "$codex_seconds" "$input_tokens" "$cached_input_tokens" "$output_tokens" "$reasoning_output_tokens" "$cost_estimate_usd" "$cost_method" "$instance_dir" "$codex_log" "$eval_log" >> "$summary_file"
    echo "    setup failed. See $setup_log"
    continue
  fi

  echo "==> $instance_id: codex exec"
  codex_started_at="$(date +%s)"
  codex_args=(
    exec
    --json
    --cd "$instance_dir"
    --dangerously-bypass-approvals-and-sandbox
    --output-last-message "$codex_final"
  )
  if [[ -n "$MODEL" ]]; then
    codex_args+=(--model "$MODEL")
  fi

  if codex "${codex_args[@]}" - < "$PROMPT_FILE" >"$codex_log" 2>&1; then
    codex_status="ok"
  else
    codex_status="failed"
  fi
  codex_finished_at="$(date +%s)"
  codex_seconds="$((codex_finished_at - codex_started_at))"

  usage_args=()
  if [[ -n "${CODEX_INPUT_USD_PER_1M:-}" ]]; then
    usage_args+=(--input-usd-per-1m "$CODEX_INPUT_USD_PER_1M")
  fi
  if [[ -n "${CODEX_CACHED_INPUT_USD_PER_1M:-}" ]]; then
    usage_args+=(--cached-input-usd-per-1m "$CODEX_CACHED_INPUT_USD_PER_1M")
  fi
  if [[ -n "${CODEX_OUTPUT_USD_PER_1M:-}" ]]; then
    usage_args+=(--output-usd-per-1m "$CODEX_OUTPUT_USD_PER_1M")
  fi

  if python "$SCRIPT_DIR/extract_codex_usage.py" \
      --jsonl "$codex_log" \
      --output "$codex_usage" \
      --model "$COST_MODEL" \
      "${usage_args[@]}"; then
    input_tokens="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["input_tokens"])' "$codex_usage")"
    cached_input_tokens="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["cached_input_tokens"])' "$codex_usage")"
    output_tokens="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["output_tokens"])' "$codex_usage")"
    reasoning_output_tokens="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["reasoning_output_tokens"])' "$codex_usage")"
    cost_estimate_usd="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["cost_estimate_usd"])' "$codex_usage")"
    cost_method="$(python -c 'import json,sys; print(json.load(open(sys.argv[1]))["cost_method"])' "$codex_usage")"
  fi

  git -C "$instance_dir" diff --binary > "$patch_file"

  eval_status="not_run"
  resolved="unknown"
  if [[ "$codex_status" != "ok" ]]; then
    eval_status="skipped_codex_failed"
  elif [[ ! -s "$patch_file" ]]; then
    eval_status="skipped_empty_patch"
  elif [[ "$EVALUATE" == "1" ]]; then
    echo "==> $instance_id: harness evaluation"
    if INSTANCE_ID="$instance_id" DATASET_NAME="$DATASET_NAME" SPLIT="$SPLIT" INSTANCE_DIR="$instance_dir" INSTANCES_DIR="$auto_instances_dir" "$SCRIPT_DIR/eval_patch.sh" >"$eval_log" 2>&1; then
      eval_status="ok"
    else
      eval_status="failed"
    fi

    report_path="$(sed -n 's/^Instance report: //p' "$eval_log" | tail -n 1)"
    if [[ -n "$report_path" && -f "$report_path" ]]; then
      resolved="$(
        REPORT_PATH="$report_path" INSTANCE_ID="$instance_id" python - <<'PY'
import json
import os

with open(os.environ["REPORT_PATH"], encoding="utf-8") as f:
    report = json.load(f)
print(str(bool(report[os.environ["INSTANCE_ID"]]["resolved"])).lower())
PY
      )"
    fi
  fi

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" "$instance_id" "$codex_status" "$eval_status" "$resolved" "$codex_seconds" "$input_tokens" "$cached_input_tokens" "$output_tokens" "$reasoning_output_tokens" "$cost_estimate_usd" "$cost_method" "$instance_dir" "$codex_log" "$eval_log" >> "$summary_file"
  echo "    codex=$codex_status eval=$eval_status resolved=$resolved seconds=$codex_seconds tokens_in=$input_tokens tokens_cached=$cached_input_tokens tokens_out=$output_tokens cost_estimate_usd=$cost_estimate_usd"
done < "$ids_file"

echo
echo "Automatic baseline run finished."
echo "Instance IDs: $ids_file"
echo "Summary: $summary_file"
echo "Per-instance logs: $run_dir"
