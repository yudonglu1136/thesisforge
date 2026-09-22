#!/usr/bin/env python3
"""Rebuild the bounded AI Insights read model without network access."""
import argparse
import json
import os
from pathlib import Path
import sys

PROJECT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(PROJECT))
from fact_os.ai_insights import DEFAULT_UNIVERSE, build_ai_insights


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root', type=Path, default=Path(os.environ.get('FACT_OS_ROOT', PROJECT / 'data/fact_os')))
    parser.add_argument('--universe', type=Path, default=DEFAULT_UNIVERSE)
    args = parser.parse_args()
    result = build_ai_insights(args.root, universe_path=args.universe)
    print(json.dumps(result, default=str))
    return 0


if __name__ == '__main__':
    sys.exit(main())
