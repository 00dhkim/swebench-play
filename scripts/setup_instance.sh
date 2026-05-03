#!/usr/bin/env bash
set -euo pipefail

DATASET_NAME="${DATASET_NAME:-princeton-nlp/SWE-bench_Verified}"
SPLIT="${SPLIT:-test}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SWE_PLAY_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SWE_BENCH_DIR="$ROOT_DIR/SWE-bench"
INSTANCES_DIR="$ROOT_DIR/instances"

if [[ -z "${INSTANCE_ID:-}" ]]; then
  echo "ERROR: INSTANCE_ID is required." >&2
  echo "Example: INSTANCE_ID=django__django-11099 $0" >&2
  exit 2
fi

if [[ ! -d "$SWE_BENCH_DIR/.venv" ]]; then
  echo "ERROR: SWE-bench venv not found at $SWE_BENCH_DIR/.venv" >&2
  exit 2
fi

source "$SWE_BENCH_DIR/.venv/bin/activate"
mkdir -p "$INSTANCES_DIR"

INSTANCE_DIR="$INSTANCES_DIR/$INSTANCE_ID"
ISSUE_FILE="$INSTANCE_DIR/issue.md"
tmp_dir="$(mktemp -d)"
TMP_ISSUE_FILE="$tmp_dir/issue.md"
METADATA_FILE="$tmp_dir/swe_instance_metadata.env"
trap 'rm -rf "$tmp_dir"' EXIT

mkdir -p "$INSTANCE_DIR"

DATASET_NAME="$DATASET_NAME" SPLIT="$SPLIT" INSTANCE_ID="$INSTANCE_ID" ISSUE_FILE="$TMP_ISSUE_FILE" METADATA_FILE="$METADATA_FILE" python - <<'PY'
import os
import shlex
import sys
from pathlib import Path

from datasets import load_dataset

dataset_name = os.environ["DATASET_NAME"]
split = os.environ["SPLIT"]
instance_id = os.environ["INSTANCE_ID"]
issue_file = Path(os.environ["ISSUE_FILE"])
metadata_file = Path(os.environ["METADATA_FILE"])

dataset = load_dataset(dataset_name, split=split)
item = next((row for row in dataset if row["instance_id"] == instance_id), None)
if item is None:
    print(f"ERROR: instance_id not found: {instance_id}", file=sys.stderr)
    sys.exit(1)

issue_file.write_text(item["problem_statement"].rstrip() + "\n", encoding="utf-8")

repo = item["repo"]
base_commit = item["base_commit"]
repo_url = f"https://github.com/{repo}.git"
metadata_file.write_text(
    "\n".join(
        [
            f"REPO={shlex.quote(repo)}",
            f"REPO_URL={shlex.quote(repo_url)}",
            f"BASE_COMMIT={shlex.quote(base_commit)}",
            "",
        ]
    ),
    encoding="utf-8",
)
PY

source "$METADATA_FILE"

if [[ ! -d "$INSTANCE_DIR/.git" ]]; then
  clone_tmp="$tmp_dir/repo"
  git clone "$REPO_URL" "$clone_tmp"
  find "$INSTANCE_DIR" -mindepth 1 -exec rm -rf {} +
  shopt -s dotglob nullglob
  mv "$clone_tmp"/* "$INSTANCE_DIR"/
  shopt -u dotglob nullglob
fi

git -C "$INSTANCE_DIR" fetch --all --tags --prune
git -C "$INSTANCE_DIR" checkout --detach "$BASE_COMMIT"
git -C "$INSTANCE_DIR" clean -fdx
cp "$TMP_ISSUE_FILE" "$ISSUE_FILE"
cp "$ISSUE_FILE" "$INSTANCE_DIR/SWE_ISSUE.md"

cat <<EOF
Instance is ready.

Dataset: $DATASET_NAME
Split: $SPLIT
Instance: $INSTANCE_ID
Repo: $REPO
Base commit: $BASE_COMMIT
Worktree: $INSTANCE_DIR
Issue file: $INSTANCE_DIR/SWE_ISSUE.md

Next commands:
  cd "$INSTANCE_DIR"
  codex
EOF
