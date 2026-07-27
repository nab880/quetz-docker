#!/usr/bin/env python3
"""Write a schema-shaped Quetz ERROR result before an oracle can run."""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--oracle-id", default="runner-setup")
    parser.add_argument("--detail", required=True)
    args = parser.parse_args()
    result = {
        "schema_version": 1,
        "run_id": "runner-setup-error",
        "oracle_id": args.oracle_id,
        "outcome": "ERROR",
        "duration_ms": 0,
        "completion": {
            "id": "completion",
            "passed": False,
            "matched_count": 0,
            "matched_sequences": [],
            "detail": args.detail,
        },
        "expectation_results": [],
        "safety_results": [],
        "provenance": {
            "run_manifest_sha256": None,
            "workspace_manifest_sha256": None,
        },
        "artifacts": [],
        "first_failure": {
            "reason": args.detail,
            "sequence": None,
            "context_before": [],
            "context_after": [],
        },
    }
    args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
