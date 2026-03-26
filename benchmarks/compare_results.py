"""
LakeTS Benchmark Comparison Tool
Compares LakeTS benchmark results against TimescaleDB baselines.

Usage:
  python compare_results.py --lakets results_lakets.json --timescale results_tsdb.json
  python compare_results.py --lakets results_lakets.json  # Compare against published baselines
"""
import argparse
import json
import sys

# Published TimescaleDB baselines (approximate, from TSBS and public benchmarks)
# These are representative values; actual results vary by hardware and config.
TIMESCALEDB_BASELINES = {
    "Ingest": {"value": 500000, "unit": "rows/sec", "source": "TSBS on 8-core, 32GB"},
    "Simple Query (last per device)": {"value": 5.0, "unit": "ms (median)", "source": "100 devices"},
    "Aggregation (hourly rollup)": {"value": 50.0, "unit": "ms", "source": "1M rows"},
    "Gap-Fill (hourly LOCF)": {"value": 10.0, "unit": "ms", "source": "7-day range"},
    "RollUp": {"value": 200.0, "unit": "ms (refresh)", "source": "1M rows"},
}


def compare(lakets_results: dict, tsdb_results: dict = None):
    """Compare LakeTS results against TimescaleDB baselines."""
    if tsdb_results is None:
        tsdb_results = TIMESCALEDB_BASELINES

    print("=" * 80)
    print(f"  LakeTS vs TimescaleDB Benchmark Comparison")
    print(f"  LakeTS rows: {lakets_results.get('num_rows', 'N/A'):,}")
    print("=" * 80)
    print(f"{'Benchmark':<35} {'LakeTS':>12} {'TimescaleDB':>12} {'Ratio':>8} {'Winner':>10}")
    print("-" * 80)

    for result in lakets_results.get("results", []):
        name = result["name"]
        lakets_val = result["value"]
        unit = result["unit"]

        tsdb = tsdb_results.get(name, {})
        tsdb_val = tsdb.get("value")

        if tsdb_val is None:
            print(f"{name:<35} {lakets_val:>10.2f} {'N/A':>12} {'N/A':>8} {'—':>10}")
            continue

        # For latency metrics, lower is better; for throughput, higher is better
        is_throughput = "rows/sec" in unit
        if is_throughput:
            ratio = lakets_val / tsdb_val if tsdb_val > 0 else 0
            winner = "LakeTS" if ratio >= 1.0 else "TSDB"
        else:
            ratio = tsdb_val / lakets_val if lakets_val > 0 else 0
            winner = "LakeTS" if ratio >= 1.0 else "TSDB"

        print(f"{name:<35} {lakets_val:>10.2f} {tsdb_val:>10.2f} {ratio:>7.2f}x {winner:>10}")

    print("-" * 80)
    print("Note: TimescaleDB baselines are approximate published values.")
    print("      Run TimescaleDB benchmarks on equivalent hardware for accurate comparison.")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Compare LakeTS vs TimescaleDB benchmarks")
    parser.add_argument("--lakets", required=True, help="LakeTS results JSON file")
    parser.add_argument("--timescale", help="TimescaleDB results JSON file (optional)")
    args = parser.parse_args()

    with open(args.lakets) as f:
        lakets = json.load(f)

    tsdb = None
    if args.timescale:
        with open(args.timescale) as f:
            tsdb = json.load(f)

    compare(lakets, tsdb)
