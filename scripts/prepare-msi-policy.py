#!/usr/bin/env python3
"""Retain the current source installer policy before final payload inventory."""
import argparse
import importlib.util
from pathlib import Path
import tempfile

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source',required=True,type=Path)
    parser.add_argument('--stage',required=True,type=Path)
    parser.add_argument('--version',required=True)
    args=parser.parse_args()
    source=args.source.resolve(strict=True)
    if not source.is_relative_to(ROOT):raise ValueError('installer source must be current repository authoring')
    spec=importlib.util.spec_from_file_location('client_inventory',ROOT/'scripts/release-inventory.py')
    inventory=importlib.util.module_from_spec(spec);spec.loader.exec_module(inventory)
    environment=inventory.clean_environment();revision=inventory.run(['git','rev-parse','HEAD'],ROOT,environment)
    with tempfile.TemporaryDirectory(prefix='client-msi-policy-') as temporary:
        tools=inventory.checkout_tools(Path(temporary)/'tools',environment)
        module=inventory.load_tool('msi_policy',tools)
        (args.stage/'share').mkdir(mode=0o755,exist_ok=True)
        module.create(source,args.stage,args.version,revision)


if __name__=='__main__':main()
