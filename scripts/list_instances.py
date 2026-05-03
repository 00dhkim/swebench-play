#!/usr/bin/env python3
import argparse
import sys

from datasets import load_dataset


DEFAULT_DATASET = "princeton-nlp/SWE-bench_Verified"
DEFAULT_SPLIT = "test"


def first_line(text: str) -> str:
    for line in text.splitlines():
        stripped = line.strip()
        if stripped:
            return stripped
    return ""


def main() -> int:
    parser = argparse.ArgumentParser(
        description="List SWE-bench Verified instances without exposing patches."
    )
    parser.add_argument("n", nargs="?", type=int, default=50)
    parser.add_argument("--dataset", default=DEFAULT_DATASET)
    parser.add_argument("--split", default=DEFAULT_SPLIT)
    args = parser.parse_args()

    dataset = load_dataset(args.dataset, split=args.split)
    limit = min(args.n, len(dataset))

    for index in range(limit):
        item = dataset[index]
        statement = first_line(item.get("problem_statement", ""))
        print(
            f"{index}\t{item['instance_id']}\t{item['repo']}\t{statement}",
            flush=True,
        )
    return 0


if __name__ == "__main__":
    sys.exit(main())
