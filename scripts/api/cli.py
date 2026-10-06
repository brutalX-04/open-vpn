#!/usr/bin/env python3
"""Compatibility launcher for the new vpnctl package (completed in phase 7)."""
import os
import sys

sys.path.insert(0, os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..")))
from vpnctl.cli import main


if __name__ == "__main__":
    raise SystemExit(main())
