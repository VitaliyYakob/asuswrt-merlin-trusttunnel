#!/usr/bin/env python3
"""Compatibility entry point: the maintained browser suite uses Playwright for Node."""
from pathlib import Path
import subprocess
import sys

if __name__ == "__main__":
    raise SystemExit(subprocess.call(["node", str(Path(__file__).with_suffix(".js"))]))
