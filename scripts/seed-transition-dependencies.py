#!/usr/bin/env python3
"""Physically copy native dependency outputs into a fresh fixture target.

Never seed the xsoc workspace crate, its fingerprints/build scripts, or product
executables. Cargo still builds the fixture from its own controlled source and
identity. Copying avoids a second archive download/extraction on Windows.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import stat
import time

TARGET = "x86_64-pc-windows-msvc"
OWN_ARTIFACT = re.compile(r"^(?:lib)?xsoc(?:[-_.]|$)", re.IGNORECASE)


def regular_metadata(path: Path):
    metadata = path.lstat()
    if stat.S_ISLNK(metadata.st_mode) or getattr(metadata, "st_file_attributes", 0) & getattr(stat, "FILE_ATTRIBUTE_REPARSE_POINT", 0):
        raise ValueError(f"dependency seed refuses links/reparse points: {path}")
    if not (stat.S_ISDIR(metadata.st_mode) or stat.S_ISREG(metadata.st_mode)):
        raise ValueError(f"dependency seed refuses special files: {path}")
    return metadata


def seed(source: Path, destination: Path) -> dict:
    started = time.monotonic()
    regular_metadata(source)
    if destination.exists() or destination.is_symlink():
        raise ValueError("fixture target must be fresh")
    source = source.resolve(strict=True)
    destination = destination.resolve()
    if destination.is_relative_to(source) or source.is_relative_to(destination):
        raise ValueError("fixture target must be independent of the native target")
    if not (source / TARGET / "release").is_dir():
        raise ValueError("native Windows release dependency outputs are missing")
    destination.mkdir(parents=True)
    counts = {"files": 0, "bytes": 0}

    def copy_tree(original: Path, copied: Path):
        metadata = regular_metadata(original)
        if original.is_dir():
            copied.mkdir()
            for child in original.iterdir():
                if not OWN_ARTIFACT.match(child.name):
                    copy_tree(child, copied / child.name)
            shutil.copystat(original, copied, follow_symlinks=False)
        else:
            # copy2 creates independent regular files, never hard links.
            shutil.copy2(original, copied, follow_symlinks=False)
            result = regular_metadata(copied)
            if result.st_nlink != 1 or os.path.samefile(original, copied) or result.st_size != metadata.st_size:
                raise ValueError(f"fixture dependency copy is not independent: {copied}")
            counts["files"] += 1
            counts["bytes"] += result.st_size

    # Include host build scripts/proc macros and target dependencies, but no
    # incremental directories, examples, top-level binaries or whole source tree.
    for profile in (Path("release"), Path(TARGET) / "release"):
        if (source / profile).exists():
            regular_metadata(source / profile)
        for category in (".fingerprint", "build", "deps"):
            original = source / profile / category
            if original.exists():
                parent = destination / profile
                parent.mkdir(parents=True, exist_ok=True)
                copy_tree(original, parent / category)
    counts["seconds"] = round(time.monotonic() - started, 3)
    return counts


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", required=True, type=Path)
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    print("Transition dependency seed: " + json.dumps(seed(args.source, args.destination), sort_keys=True), flush=True)


if __name__ == "__main__":
    main()
