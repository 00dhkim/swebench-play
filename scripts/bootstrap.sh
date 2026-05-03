#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="${SWE_PLAY_ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"
SWE_BENCH_DIR="$ROOT_DIR/SWE-bench"
SWE_BENCH_REPO_URL="${SWE_BENCH_REPO_URL:-https://github.com/SWE-bench/SWE-bench.git}"

usage() {
  cat <<'EOF'
Usage:
  scripts/bootstrap.sh

Environment variables:
  SWE_PLAY_ROOT       Optional project root override
  SWE_BENCH_REPO_URL  Optional SWE-bench repository URL override
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

if ! command -v git >/dev/null 2>&1; then
  echo "ERROR: git is required." >&2
  exit 2
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "ERROR: python3 is required." >&2
  exit 2
fi

if [[ ! -d "$SWE_BENCH_DIR/.git" ]]; then
  if [[ -e "$SWE_BENCH_DIR" ]]; then
    echo "ERROR: $SWE_BENCH_DIR exists but is not a git repository." >&2
    exit 2
  fi
  git clone "$SWE_BENCH_REPO_URL" "$SWE_BENCH_DIR"
fi

cd "$SWE_BENCH_DIR"

if [[ ! -d .venv ]]; then
  python3 -m venv .venv
fi

source .venv/bin/activate
python -m pip install --upgrade pip setuptools wheel
python -m pip install -e .

python - <<'PY'
import swebench

print("swebench import ok")
PY

cat <<EOF

Bootstrap complete.

SWE-bench directory: $SWE_BENCH_DIR
Virtualenv: $SWE_BENCH_DIR/.venv

Next commands:
  cd "$ROOT_DIR/SWE-bench"
  source .venv/bin/activate
  python ../scripts/list_instances.py 20
EOF
