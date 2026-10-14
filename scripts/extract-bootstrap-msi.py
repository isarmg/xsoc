#!/usr/bin/env python3
"""Read the bootstrap MSI without running installation actions."""
import argparse
import importlib.util
from pathlib import Path
import shutil
import tempfile

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bootstrap-msi',type=Path,required=True)
    parser.add_argument('--stage',type=Path,required=True)
    args=parser.parse_args()
    spec=importlib.util.spec_from_file_location('client_inventory',ROOT/'scripts/release-inventory.py')
    inventory=importlib.util.module_from_spec(spec);spec.loader.exec_module(inventory)
    with tempfile.TemporaryDirectory(prefix='xsoc-bootstrap-inventory-') as temporary:
        private=Path(temporary).resolve(strict=True);tools=inventory.checkout_tools(private/'tools',inventory.clean_environment())
        extractor=inventory.load_tool('native_package',tools)
        payload,_=extractor.msi_payload(args.bootstrap_msi.resolve(strict=True),private/'msi',include_embedded=True)
        shutil.copytree(payload,args.stage)


if __name__=='__main__':main()
