#!/usr/bin/env python3
"""Install locked crates.io inventory tools, or validate an exact CI cache hit.

The cache is an optimization of source-built tools, not an audit/SBOM cache.
GitHub's branch-scoped cache is the trust boundary; the manifest detects broken
or partial cache restores and is not an independent publisher signature.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess

TOOLS = {"cargo-audit": "0.22.2", "cargo-cyclonedx": "0.5.9"}


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def verify(root: Path) -> None:
    manifest = json.loads((root / "manifest.json").read_text(encoding="utf-8"))
    if manifest.get("versions") != TOOLS:
        raise ValueError("cached inventory tool versions differ")
    suffix = ".exe" if os.name == "nt" else ""
    expected = {name + suffix for name in TOOLS}
    if set(manifest.get("sha256", {})) != expected:
        raise ValueError("cached inventory manifest has unexpected binaries")
    for name in expected:
        binary = root / "bin" / name
        if binary.is_symlink() or digest(binary) != manifest["sha256"][name]:
            raise ValueError(f"cached inventory binary checksum mismatch: {name}")
    # Verify checksums before executing anything from the cache. Use Cargo's
    # normal subcommand interface, which both tools support.
    env = dict(os.environ, PATH=str(root / "bin") + os.pathsep + os.environ["PATH"])
    for name, version in TOOLS.items():
        output = subprocess.check_output(["cargo", name.removeprefix("cargo-"), "--version"], env=env, text=True)
        if re.search(rf"(?<![\d.]){re.escape(version)}(?![\d.])", output) is None:
            raise ValueError(f"unexpected {name} version: {output!r}")
        print(output.strip())


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--cache-hit", choices=("true", "false"), default="false")
    args = parser.parse_args()
    root = args.root.resolve()
    if args.cache_hit != "true":
        if root.exists():
            raise ValueError("cache miss must use a fresh isolated tool root")
        for name, version in TOOLS.items():
            subprocess.run(["cargo", "install", "--locked", "--registry", "crates-io", "--root", str(root), name, "--version", version], check=True)
        suffix = ".exe" if os.name == "nt" else ""
        manifest = {"versions": TOOLS, "sha256": {name + suffix: digest(root / "bin" / (name + suffix)) for name in TOOLS}}
        (root / "manifest.json").write_text(json.dumps(manifest, sort_keys=True) + "\n", encoding="utf-8")
    verify(root)
    with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as output:
        output.write(str(root / "bin") + "\n")


if __name__ == "__main__":
    main()
