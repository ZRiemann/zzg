#!/usr/bin/env python3
"""Locate Forge and invoke zzg's native engineering definition."""
from __future__ import annotations

import os
import sys
from pathlib import Path


def main() -> int:
    root = Path(__file__).resolve().parent
    configured_root = os.environ.get("ZETAX_ROOT", str(root.parent))
    workspace = Path(os.path.expandvars(os.path.expanduser(configured_root))).resolve()
    common = workspace / "zeta_forge" / "common"
    if not (common / "zeta_forge" / "zig_engine.py").is_file():
        print(f"Forge Zig support is missing: {common}", file=sys.stderr)
        return 1
    sys.path.insert(0, str(common))
    from zeta_forge.build_cli import cli
    from builder.zzg import project

    return cli(project(root))


if __name__ == "__main__":
    raise SystemExit(main())
