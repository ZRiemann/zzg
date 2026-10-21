"""Native libraries and explicitly selected runnable examples."""
from pathlib import Path

from zeta_forge.build_cli import Product, Project
from zeta_forge.zig_engine import ZigEngine, ZigTarget


def project(root: Path) -> Project:
    actions = ("doctor", "check", "build", "rebuild", "test", "clean")
    targets = {
        "zzg": ZigTarget("zzg"),
        "zzg-log": ZigTarget("zzg-log"),
        "logging": ZigTarget("logging", "logging"),
        "benchmark": ZigTarget("benchmark", "benchmark"),
    }
    descriptions = (
        ("zzg", "ZetaX z component facade"),
        ("zzg-log", "Standalone z.log component"),
        ("logging", "Logging example (explicit)"),
        ("benchmark", "Logging benchmark (explicit)"),
    )
    products = tuple(
        Product(
            name, "zig", description,
            actions + (("run", "dev") if targets[name].executable else ()),
        )
        for name, description in descriptions
    )
    return Project("zzg", products, {"zig": ZigEngine(root, targets)}, ("zzg",))
