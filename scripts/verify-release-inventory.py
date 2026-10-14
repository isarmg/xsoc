#!/usr/bin/env python3
"""Finalize and independently verify the final Client release inventory."""
import argparse
import importlib.util
from pathlib import Path
import re
import sys
import tempfile
import tomllib

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage',required=True,type=Path)
    parser.add_argument('--target',required=True)
    args=parser.parse_args()
    spec=importlib.util.spec_from_file_location('client_release_inventory',ROOT/'scripts/release-inventory.py')
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    environment=module.clean_environment()
    profile=tomllib.loads((ROOT/'xcsc-client.toml').read_text())
    manifest=tomllib.loads((ROOT/'Cargo.toml').read_text())
    version=manifest.get('package',{}).get('version')
    if version is None or version=={'workspace':True}:
        version=manifest.get('workspace',{}).get('package',{}).get('version')
    if not isinstance(version,str) or not re.fullmatch(r'[0-9]+\.[0-9]+\.[0-9]+(?:-rc\.[0-9]+)?',version):
        raise ValueError('release software version is not its exact current Cargo identity')
    revision=module.run(['git','rev-parse','HEAD'],ROOT,environment)
    with tempfile.TemporaryDirectory(prefix='client-release-checksums-') as temporary:
        tools=module.checkout_tools(Path(temporary)/'tools',environment)
        verifier=tools/'scripts/release_manifest.py'
        module.run([sys.executable,str(verifier),'finalize',str(args.stage),
            '--product',profile['product_id'],'--version',version,
            '--source-revision',revision,'--target',args.target],ROOT,environment)
        module.run([sys.executable,str(verifier),'verify',str(args.stage)],ROOT,environment)


if __name__=='__main__':main()
