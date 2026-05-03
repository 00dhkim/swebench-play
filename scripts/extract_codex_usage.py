#!/usr/bin/env python3
import argparse
import json
import sys
from decimal import Decimal, ROUND_HALF_UP
from pathlib import Path


DEFAULT_PRICES = {
    "gpt-5.5": ("5.00", "0.50", "30.00"),
    "gpt-5.4": ("2.50", "0.25", "15.00"),
    "gpt-5.4-mini": ("0.75", "0.075", "4.50"),
    "gpt-5.3-codex": ("1.75", "0.175", "14.00"),
    "gpt-5.2": ("1.75", "0.175", "14.00"),
}


def parse_decimal(value: str | None) -> Decimal | None:
    if value in (None, ""):
        return None
    return Decimal(str(value))


def load_usage(jsonl_path: Path) -> dict:
    latest_usage = None
    with jsonl_path.open(encoding="utf-8") as handle:
        for line in handle:
            line = line.strip()
            if not line.startswith("{"):
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                continue
            if event.get("type") == "turn.completed" and event.get("usage"):
                latest_usage = event["usage"]
    if latest_usage is None:
        raise ValueError(f"No turn.completed usage found in {jsonl_path}")
    return latest_usage


def resolve_prices(args: argparse.Namespace) -> tuple[Decimal, Decimal, Decimal, str]:
    defaults = DEFAULT_PRICES.get(args.model)
    input_price = parse_decimal(args.input_usd_per_1m)
    cached_price = parse_decimal(args.cached_input_usd_per_1m)
    output_price = parse_decimal(args.output_usd_per_1m)

    if defaults:
        input_price = input_price if input_price is not None else Decimal(defaults[0])
        cached_price = cached_price if cached_price is not None else Decimal(defaults[1])
        output_price = output_price if output_price is not None else Decimal(defaults[2])

    if input_price is None or cached_price is None or output_price is None:
        raise ValueError(
            "No default prices for model "
            f"{args.model!r}. Set CODEX_INPUT_USD_PER_1M, "
            "CODEX_CACHED_INPUT_USD_PER_1M, and CODEX_OUTPUT_USD_PER_1M."
        )

    method = (
        f"api_usd_estimate:{args.model}:"
        "reasoning_output_tokens_billed_as_output:"
        "input_tokens_minus_cached_input_tokens"
    )
    return input_price, cached_price, output_price, method


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Extract token usage and estimate USD cost from Codex JSONL output."
    )
    parser.add_argument("--jsonl", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--model", required=True)
    parser.add_argument("--input-usd-per-1m")
    parser.add_argument("--cached-input-usd-per-1m")
    parser.add_argument("--output-usd-per-1m")
    args = parser.parse_args()

    try:
        usage = load_usage(args.jsonl)
        input_price, cached_price, output_price, method = resolve_prices(args)
    except Exception as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    input_tokens = int(usage.get("input_tokens", 0) or 0)
    cached_input_tokens = int(usage.get("cached_input_tokens", 0) or 0)
    output_tokens = int(usage.get("output_tokens", 0) or 0)
    reasoning_output_tokens = int(usage.get("reasoning_output_tokens", 0) or 0)

    billable_uncached_input = max(input_tokens - cached_input_tokens, 0)
    cost = (
        Decimal(billable_uncached_input) * input_price
        + Decimal(cached_input_tokens) * cached_price
        + Decimal(output_tokens) * output_price
    ) / Decimal(1_000_000)

    result = {
        "model": args.model,
        "input_tokens": input_tokens,
        "cached_input_tokens": cached_input_tokens,
        "output_tokens": output_tokens,
        "reasoning_output_tokens": reasoning_output_tokens,
        "billable_uncached_input_tokens": billable_uncached_input,
        "input_usd_per_1m": str(input_price),
        "cached_input_usd_per_1m": str(cached_price),
        "output_usd_per_1m": str(output_price),
        "cost_estimate_usd": str(cost.quantize(Decimal("0.000001"), rounding=ROUND_HALF_UP)),
        "cost_method": method,
    }
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
