#!/usr/bin/env python3
"""Verify final native installers and produce a SHA256-bound outer delivery."""
import argparse
import importlib.util
import json
from pathlib import Path
import shutil
import tarfile
import tempfile
import tomllib

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--artifact',action='append',required=True,type=Path)
    parser.add_argument('--inner-bom',action='append',required=True,type=Path)
    parser.add_argument('--target',required=True)
    parser.add_argument('--stage',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    if len(args.artifact)!=len(args.inner_bom):raise ValueError('each native installer requires its exact inner inventory')
    args.stage.mkdir(mode=0o755,parents=True,exist_ok=False)
    profile=tomllib.loads((ROOT/'xcsc-client.toml').read_text())
    manifest=tomllib.loads((ROOT/'Cargo.toml').read_text())
    version=manifest.get('package',{}).get('version')
    if version is None or version=={'workspace':True}:version=manifest['workspace']['package']['version']
    spec=importlib.util.spec_from_file_location('client_inventory',ROOT/'scripts/release-inventory.py')
    inventory=importlib.util.module_from_spec(spec);spec.loader.exec_module(inventory)
    environment=inventory.clean_environment();revision=inventory.run(['git','rev-parse','HEAD'],ROOT,environment)
    with tempfile.TemporaryDirectory(prefix='client-native-delivery-') as temporary:
        private=Path(temporary).resolve(strict=True);tools=inventory.checkout_tools(private/'tools',environment)
        extractor=inventory.load_tool('native_package',tools)
        finalizer=inventory.load_tool('release_sbom',tools)
        checksums=inventory.load_tool('release_manifest',tools)
        receipts=[]
        for artifact,inner in zip(args.artifact,args.inner_bom,strict=True):
            if artifact.is_symlink() or inner.is_symlink() or not artifact.is_file() or not inner.is_file():
                raise ValueError('native package inputs must be physical current build files')
            copied=args.stage/artifact.name;copied_inner=args.stage/(artifact.name+'.inner-sbom.cdx.json')
            if copied.exists() or copied_inner.exists():raise ValueError('native package names are ambiguous')
            shutil.copyfile(artifact,copied);shutil.copyfile(inner,copied_inner)
            copied.chmod(0o644);copied_inner.chmod(0o644)
            receipts.append(extractor.materialize(args.stage,copied,copied_inner,artifact.suffix[1:]))
        external=private/'bindings.json'
        external.write_text(json.dumps({'format_version':1,'runtime_roots':[],'components':[]}))
        finalizer.finalize(args.stage,[],external,profile['product_id'],version,revision,args.target,native_packages=receipts)
        checksums.finalize(args.stage,profile['product_id'],version,revision,args.target)
        checksums.verify(args.stage)
    args.output.parent.mkdir(parents=True,exist_ok=True)
    with tarfile.open(args.output,'x:gz') as archive:archive.add(args.stage,arcname='.')
    args.output.with_name(args.output.name+'.sha256').write_text(inventory.file_binding(args.output.parent,{'path':args.output.name,'archive_entry':None})['sha256']+'  '+args.output.name+'\n')


if __name__=='__main__':main()
