#!/usr/bin/env bash
set -euo pipefail

DATASET_NAME="${DATASET_NAME:-princeton-nlp/SWE-bench_Verified}"
SPLIT="${SPLIT:-test}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SWE_PLAY_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SWE_BENCH_DIR="$ROOT_DIR/SWE-bench"
INSTANCES_DIR="$ROOT_DIR/instances"
MODEL_NAME="human-codex-practice"

if [[ -z "${INSTANCE_ID:-}" ]]; then
  echo "ERROR: INSTANCE_ID is required." >&2
  echo "Example: INSTANCE_ID=django__django-11099 $0" >&2
  exit 2
fi

INSTANCE_DIR="${INSTANCE_DIR:-$INSTANCES_DIR/$INSTANCE_ID}"
if [[ ! -d "$INSTANCE_DIR/.git" ]]; then
  echo "ERROR: instance repo not found at $INSTANCE_DIR" >&2
  exit 2
fi

if [[ ! -d "$SWE_BENCH_DIR/.venv" ]]; then
  echo "ERROR: SWE-bench venv not found at $SWE_BENCH_DIR/.venv" >&2
  exit 2
fi

source "$SWE_BENCH_DIR/.venv/bin/activate"
mkdir -p "$SWE_BENCH_DIR/runs"

timestamp="$(date -u +%Y%m%dT%H%M%SZ)"
safe_instance_id="${INSTANCE_ID//[^A-Za-z0-9_.-]/_}"
run_id="${safe_instance_id}_${timestamp}"
run_dir="$SWE_BENCH_DIR/runs/$run_id"
mkdir -p "$run_dir"

patch_file="$run_dir/model.patch"
predictions_file="$run_dir/predictions.jsonl"

changed_test_files="$(
  git -C "$INSTANCE_DIR" diff --name-only -- \
    ':(glob)**/test_*.py' \
    ':(glob)**/*_test.py' \
    ':(glob)**/tests/**' \
    ':(glob)**/test/**' || true
)"
if [[ -n "$changed_test_files" ]]; then
  echo "ERROR: refusing to evaluate a patch that modifies test files:" >&2
  echo "$changed_test_files" >&2
  exit 3
fi

git -C "$INSTANCE_DIR" diff --binary > "$patch_file"

PATCH_FILE="$patch_file" PREDICTIONS_FILE="$predictions_file" INSTANCE_ID="$INSTANCE_ID" MODEL_NAME="$MODEL_NAME" python - <<'PY'
import json
import os
from pathlib import Path

patch = Path(os.environ["PATCH_FILE"]).read_text(encoding="utf-8")
record = {
    "instance_id": os.environ["INSTANCE_ID"],
    "model_name_or_path": os.environ["MODEL_NAME"],
    "model_patch": patch,
}
Path(os.environ["PREDICTIONS_FILE"]).write_text(
    json.dumps(record) + "\n",
    encoding="utf-8",
)
PY

cd "$SWE_BENCH_DIR"
python -m swebench.harness.run_evaluation \
  --dataset_name "$DATASET_NAME" \
  --split "$SPLIT" \
  --instance_ids "$INSTANCE_ID" \
  --predictions_path "$predictions_file" \
  --max_workers 1 \
  --cache_level env \
  --clean False \
  --run_id "$run_id" \
  --report_dir "$run_dir"

report_file="$SWE_BENCH_DIR/$MODEL_NAME.$run_id.json"
detail_log_dir="$SWE_BENCH_DIR/logs/run_evaluation/$run_id/${MODEL_NAME//\//__}/$INSTANCE_ID"

cat <<EOF
Evaluation finished.

Run ID: $run_id
Patch: $patch_file
Predictions JSONL: $predictions_file
Summary report: $report_file
Requested report dir: $run_dir
Instance report: $detail_log_dir/report.json
Test output: $detail_log_dir/test_output.txt
Run log: $detail_log_dir/run_instance.log

If it fails, summarize these files for the next Codex iteration:
  $detail_log_dir/report.json
  $detail_log_dir/test_output.txt
  $detail_log_dir/run_instance.log
EOF
