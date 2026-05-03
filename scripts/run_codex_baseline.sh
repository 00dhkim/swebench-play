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
MAX_WORKERS="${MAX_WORKERS:-4}"
DRY_RUN="${DRY_RUN:-0}"
RESUME_RUN_DIR="${RESUME_RUN_DIR:-}"
RETRY_FAILED="${RETRY_FAILED:-0}"
STOP_ON_CODEX_LIMIT="${STOP_ON_CODEX_LIMIT:-1}"
REEVALUATE="${REEVALUATE:-0}"
MODEL_NAME="${MODEL_NAME:-human-codex-practice}"

usage() {
  cat <<'EOF'
Usage:
  scripts/run_codex_baseline.sh COUNT

Environment variables:
  DATASET_NAME          Default: princeton-nlp/SWE-bench_Verified
  SPLIT                 Default: test
  START_INDEX           Dataset index to start from. Default: 0
  EVALUATE              Run SWE-bench harness after Codex attempts. Default: 1
  MAX_WORKERS           SWE-bench harness parallel workers. Default: 4
  MODEL                 Optional Codex model override
  MODEL_NAME            Harness model_name_or_path. Default: human-codex-practice
  COST_MODEL            Model name used for cost estimate. Default: MODEL or gpt-5.5
  PROMPT_FILE           Optional prompt file. Default: scripts/codex_baseline_prompt.md
  SWE_PLAY_ROOT         Optional project root override
  DRY_RUN               Print selected instance IDs and exit. Default: 0
  RESUME_RUN_DIR        Existing baseline run directory to continue
  RETRY_FAILED          Retry failed/setup_failed/codex_limit_failed rows on resume. Default: 0
  STOP_ON_CODEX_LIMIT   Stop the Codex loop after quota/rate-limit failure. Default: 1
  REEVALUATE            Re-run harness for rows with eval_status=ok. Default: 0

Cost estimate overrides:
  CODEX_INPUT_USD_PER_1M
  CODEX_CACHED_INPUT_USD_PER_1M
  CODEX_OUTPUT_USD_PER_1M

Example:
  scripts/run_codex_baseline.sh 5
  START_INDEX=20 EVALUATE=0 scripts/run_codex_baseline.sh 10
  MAX_WORKERS=8 scripts/run_codex_baseline.sh 500
  RESUME_RUN_DIR=baseline-runs/codex_20260503T100502Z scripts/run_codex_baseline.sh 500
  DRY_RUN=1 scripts/run_codex_baseline.sh 5
EOF
}

validate_positive_integer() {
  local name="$1"
  local value="$2"
  if [[ -z "$value" || ! "$value" =~ ^[0-9]+$ || "$value" -lt 1 ]]; then
    echo "ERROR: $name must be a positive integer." >&2
    exit 2
  fi
}

detect_codex_limit_error() {
  local log_file="$1"
  [[ -f "$log_file" ]] || return 1
  grep -Eiq 'rate.?limit|usage.?limit|quota|insufficient_quota|billing|too many requests|(^|[^0-9])429([^0-9]|$)' "$log_file"
}

write_summary_header() {
  local path="$1"
  printf "instance_id\tcodex_status\teval_status\tresolved\tcodex_seconds\tcodex_input_tokens\tcodex_cached_input_tokens\tcodex_output_tokens\tcodex_reasoning_output_tokens\tcodex_cost_estimate_usd\tcodex_cost_method\tinstance_dir\tcodex_log\teval_log\n" > "$path"
}

summary_has_instance() {
  local summary="$1"
  local instance_id="$2"
  [[ -f "$summary" ]] || return 1
  awk -F '\t' -v id="$instance_id" -v retry="$RETRY_FAILED" '
    NR == 1 { next }
    $1 != id { next }
    retry == "1" && ($2 == "failed" || $2 == "setup_failed" || $2 == "codex_limit_failed") { next }
    { found = 1 }
    END { exit found ? 0 : 1 }
  ' "$summary"
}

remove_summary_instance() {
  local summary="$1"
  local instance_id="$2"
  local tmp_summary="$summary.tmp"
  [[ -f "$summary" ]] || return 0
  awk -F '\t' -v OFS='\t' -v id="$instance_id" 'NR == 1 || $1 != id' "$summary" > "$tmp_summary"
  mv "$tmp_summary" "$summary"
}

append_summary_row() {
  local summary="$1"
  local instance_id="$2"
  local codex_status="$3"
  local eval_status="$4"
  local resolved="$5"
  local codex_seconds="$6"
  local input_tokens="$7"
  local cached_input_tokens="$8"
  local output_tokens="$9"
  local reasoning_output_tokens="${10}"
  local cost_estimate_usd="${11}"
  local cost_method="${12}"
  local instance_dir="${13}"
  local codex_log="${14}"
  local eval_log="${15}"

  printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
    "$instance_id" "$codex_status" "$eval_status" "$resolved" "$codex_seconds" \
    "$input_tokens" "$cached_input_tokens" "$output_tokens" "$reasoning_output_tokens" \
    "$cost_estimate_usd" "$cost_method" "$instance_dir" "$codex_log" "$eval_log" >> "$summary"
}

rewrite_summary_for_batch_eval() {
  local summary="$1"
  local updates="$2"
  local tmp_summary="$summary.tmp"

  SUMMARY_FILE="$summary" UPDATES_FILE="$updates" python - <<'PY' > "$tmp_summary"
import csv
import os
import sys

summary_file = os.environ["SUMMARY_FILE"]
updates_file = os.environ["UPDATES_FILE"]
updates = {}

if os.path.exists(updates_file):
    with open(updates_file, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle, delimiter="\t")
        for row in reader:
            updates[row["instance_id"]] = row

with open(summary_file, newline="", encoding="utf-8") as handle:
    reader = csv.DictReader(handle, delimiter="\t")
    fieldnames = reader.fieldnames
    if fieldnames is None:
        sys.exit("summary has no header")
    writer = csv.DictWriter(sys.stdout, fieldnames=fieldnames, delimiter="\t", lineterminator="\n")
    writer.writeheader()
    for row in reader:
        update = updates.get(row["instance_id"])
        if update:
            row["eval_status"] = update["eval_status"]
            row["resolved"] = update["resolved"]
            row["eval_log"] = update["eval_log"]
        writer.writerow(row)
PY
  mv "$tmp_summary" "$summary"
}

run_batch_evaluation() {
  local run_dir="$1"
  local summary_file="$2"
  local timestamp
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  local run_id="baseline_$(basename "$run_dir")_${timestamp}"
  local batch_dir="$run_dir/batch_eval/$run_id"
  local predictions_file="$batch_dir/predictions.jsonl"
  local candidates_file="$batch_dir/candidates.tsv"
  local updates_file="$batch_dir/eval_updates.tsv"
  local eval_log="$batch_dir/eval.log"
  local report_dir="$batch_dir/report"

  mkdir -p "$batch_dir" "$report_dir"
  printf "instance_id\teval_status\tresolved\teval_log\n" > "$updates_file"
  : > "$predictions_file"
  : > "$candidates_file"

  echo
  echo "Preparing batch harness evaluation."
  echo "Run ID: $run_id"
  echo "Max workers: $MAX_WORKERS"

  while IFS=$'\t' read -r instance_id codex_status eval_status resolved codex_seconds input_tokens cached_input_tokens output_tokens reasoning_output_tokens cost_estimate_usd cost_method instance_dir codex_log row_eval_log; do
    [[ "$instance_id" != "instance_id" ]] || continue
    [[ -n "$instance_id" ]] || continue

    local instance_eval_log="$run_dir/$instance_id/eval.log"
    local patch_file="$run_dir/$instance_id/model.patch"

    if [[ "$eval_status" == "ok" && "$REEVALUATE" != "1" ]]; then
      continue
    fi
    if [[ "$codex_status" != "ok" ]]; then
      printf "%s\t%s\tunknown\t%s\n" "$instance_id" "skipped_codex_failed" "$instance_eval_log" >> "$updates_file"
      continue
    fi
    if [[ ! -s "$patch_file" ]]; then
      printf "%s\t%s\tunknown\t%s\n" "$instance_id" "skipped_empty_patch" "$instance_eval_log" >> "$updates_file"
      continue
    fi

    local changed_test_files
    changed_test_files="$(
      git -C "$instance_dir" diff --name-only -- \
        ':(glob)**/test_*.py' \
        ':(glob)**/*_test.py' \
        ':(glob)**/tests/**' \
        ':(glob)**/test/**' || true
    )"
    if [[ -n "$changed_test_files" ]]; then
      {
        echo "ERROR: refusing to evaluate a patch that modifies test files:"
        echo "$changed_test_files"
      } > "$instance_eval_log"
      printf "%s\t%s\tunknown\t%s\n" "$instance_id" "skipped_test_patch" "$instance_eval_log" >> "$updates_file"
      continue
    fi

    PATCH_FILE="$patch_file" PREDICTIONS_FILE="$predictions_file" INSTANCE_ID="$instance_id" MODEL_NAME="$MODEL_NAME" python - <<'PY'
import json
import os
from pathlib import Path

patch = Path(os.environ["PATCH_FILE"]).read_text(encoding="utf-8")
record = {
    "instance_id": os.environ["INSTANCE_ID"],
    "model_name_or_path": os.environ["MODEL_NAME"],
    "model_patch": patch,
}
with Path(os.environ["PREDICTIONS_FILE"]).open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(record) + "\n")
PY
    printf "%s\n" "$instance_id" >> "$candidates_file"
  done < "$summary_file"

  if [[ ! -s "$candidates_file" ]]; then
    echo "No patches were eligible for harness evaluation."
    rewrite_summary_for_batch_eval "$summary_file" "$updates_file"
    return 0
  fi

  mapfile -t candidate_ids < "$candidates_file"
  echo "Evaluating ${#candidate_ids[@]} patch(es)."

  set +e
  (
    cd "$SWE_BENCH_DIR"
    python -m swebench.harness.run_evaluation \
      --dataset_name "$DATASET_NAME" \
      --split "$SPLIT" \
      --instance_ids "${candidate_ids[@]}" \
      --predictions_path "$predictions_file" \
      --max_workers "$MAX_WORKERS" \
      --cache_level env \
      --clean False \
      --run_id "$run_id" \
      --report_dir "$report_dir"
  ) > "$eval_log" 2>&1
  local harness_status=$?
  set -e

  local safe_model_name="${MODEL_NAME//\//__}"
  local instance_id
  for instance_id in "${candidate_ids[@]}"; do
    local detail_log_dir="$SWE_BENCH_DIR/logs/run_evaluation/$run_id/$safe_model_name/$instance_id"
    local report_path="$detail_log_dir/report.json"
    local instance_eval_log="$run_dir/$instance_id/eval.log"
    {
      echo "Batch evaluation log: $eval_log"
      echo "Run ID: $run_id"
      echo "Predictions JSONL: $predictions_file"
      echo "Summary report dir: $report_dir"
      echo "Instance report: $report_path"
      echo "Test output: $detail_log_dir/test_output.txt"
      echo "Run log: $detail_log_dir/run_instance.log"
    } > "$instance_eval_log"

    if [[ -f "$report_path" ]]; then
      local resolved
      resolved="$(
        REPORT_PATH="$report_path" INSTANCE_ID="$instance_id" python - <<'PY'
import json
import os

with open(os.environ["REPORT_PATH"], encoding="utf-8") as handle:
    report = json.load(handle)
print(str(bool(report[os.environ["INSTANCE_ID"]]["resolved"])).lower())
PY
      )"
      printf "%s\tok\t%s\t%s\n" "$instance_id" "$resolved" "$instance_eval_log" >> "$updates_file"
    else
      printf "%s\tfailed\tunknown\t%s\n" "$instance_id" "$instance_eval_log" >> "$updates_file"
    fi
  done

  rewrite_summary_for_batch_eval "$summary_file" "$updates_file"

  if [[ "$harness_status" -ne 0 ]]; then
    echo "Batch harness evaluation failed. See $eval_log"
    return "$harness_status"
  fi

  echo "Batch harness evaluation finished."
  echo "Predictions JSONL: $predictions_file"
  echo "Batch log: $eval_log"
  echo "Updated summary: $summary_file"
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

COUNT="${1:-}"
validate_positive_integer "COUNT" "$COUNT"
validate_positive_integer "MAX_WORKERS" "$MAX_WORKERS"

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

if [[ -n "$RESUME_RUN_DIR" ]]; then
  run_dir="$RESUME_RUN_DIR"
  if [[ "$run_dir" != /* ]]; then
    run_dir="$ROOT_DIR/$run_dir"
  fi
  if [[ ! -d "$run_dir" ]]; then
    echo "ERROR: RESUME_RUN_DIR not found: $run_dir" >&2
    exit 2
  fi
else
  timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
  run_dir="$BASELINE_DIR/codex_${timestamp}"
fi

auto_instances_dir="$run_dir/instances"
ids_file="$run_dir/instance_ids.txt"
summary_file="$run_dir/summary.tsv"

mkdir -p "$run_dir" "$auto_instances_dir"

if [[ -z "$RESUME_RUN_DIR" || ! -f "$ids_file" ]]; then
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
fi

if [[ ! -f "$summary_file" ]]; then
  write_summary_header "$summary_file"
fi

echo "Automatic baseline run started."
echo "Dataset: $DATASET_NAME"
echo "Split: $SPLIT"
echo "Start index: $START_INDEX"
echo "Count requested: $COUNT"
echo "Run directory: $run_dir"
echo "Evaluate: $EVALUATE"
if [[ "$EVALUATE" == "1" ]]; then
  echo "Evaluation mode: batch after Codex attempts"
  echo "Max workers: $MAX_WORKERS"
fi
if [[ -n "$RESUME_RUN_DIR" ]]; then
  echo "Resume mode: enabled"
  echo "Retry failed rows: $RETRY_FAILED"
fi
echo "Reevaluate completed rows: $REEVALUATE"
echo

if [[ "$DRY_RUN" == "1" ]]; then
  echo "DRY_RUN=1; selected instance IDs:"
  cat "$ids_file"
  echo
  echo "No setup, Codex execution, or evaluation was run."
  exit 0
fi

codex_limit_seen=0
while IFS= read -r instance_id; do
  [[ -n "$instance_id" ]] || continue

  if summary_has_instance "$summary_file" "$instance_id"; then
    echo "==> $instance_id: skipped existing summary row"
    continue
  fi
  if [[ "$RETRY_FAILED" == "1" ]]; then
    remove_summary_instance "$summary_file" "$instance_id"
  fi

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
    append_summary_row "$summary_file" "$instance_id" "setup_failed" "not_run" "unknown" "$codex_seconds" "$input_tokens" "$cached_input_tokens" "$output_tokens" "$reasoning_output_tokens" "$cost_estimate_usd" "$cost_method" "$instance_dir" "$codex_log" "$eval_log"
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
  elif detect_codex_limit_error "$codex_log"; then
    codex_status="codex_limit_failed"
    codex_limit_seen=1
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

  if [[ -d "$instance_dir/.git" ]]; then
    git -C "$instance_dir" diff --binary > "$patch_file"
  else
    : > "$patch_file"
  fi

  eval_status="not_run"
  resolved="unknown"
  if [[ "$codex_status" != "ok" ]]; then
    eval_status="skipped_codex_failed"
  elif [[ ! -s "$patch_file" ]]; then
    eval_status="skipped_empty_patch"
  fi

  append_summary_row "$summary_file" "$instance_id" "$codex_status" "$eval_status" "$resolved" "$codex_seconds" "$input_tokens" "$cached_input_tokens" "$output_tokens" "$reasoning_output_tokens" "$cost_estimate_usd" "$cost_method" "$instance_dir" "$codex_log" "$eval_log"
  echo "    codex=$codex_status eval=$eval_status resolved=$resolved seconds=$codex_seconds tokens_in=$input_tokens tokens_cached=$cached_input_tokens tokens_out=$output_tokens cost_estimate_usd=$cost_estimate_usd"

  if [[ "$codex_limit_seen" == "1" && "$STOP_ON_CODEX_LIMIT" == "1" ]]; then
    echo "    Codex quota/rate-limit failure detected; stopping Codex loop. Resume later with RESUME_RUN_DIR=$run_dir RETRY_FAILED=1."
    break
  fi
done < "$ids_file"

if [[ "$EVALUATE" == "1" ]]; then
  run_batch_evaluation "$run_dir" "$summary_file"
fi

echo
echo "Automatic baseline run finished."
echo "Instance IDs: $ids_file"
echo "Summary: $summary_file"
echo "Per-instance logs: $run_dir"
