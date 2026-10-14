#!/usr/bin/env python3
"""Stage the fixed, statically verified Linux payload and its runtime inventory."""
import argparse
import importlib.util
from pathlib import Path
import shutil

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--version',required=True)
    parser.add_argument('--target',required=True,choices=('x86_64-unknown-linux-gnu','aarch64-unknown-linux-gnu'))
    args=parser.parse_args()
    stage=ROOT/'dist/native-payload'
    if stage.exists():raise ValueError('native payload staging already exists; use a clean build directory')
    stage.mkdir(parents=True,mode=0o755)
    entries=[('target/release/xsoc','usr/bin/xsoc',0o755),
        ('config/xsoc.json.example','etc/xsoc/config.json',0o600),
        ('packaging/linux/xsoc.service','usr/lib/systemd/system/xsoc.service',0o644),
        ('packaging/linux/xsoc-gpu.conf','usr/share/xsoc/xsoc-gpu.conf',0o644),
        ('packaging/linux/purge-local-state.sh','usr/sbin/xsoc-purge',0o755),
        *[(f'packaging/linux/{name}.sh',f'installer-scripts/{name}.sh',0o755)
          for name in ('postinstall','preremove','postremove')]]
    for source,relative,mode in entries:
        destination=stage/relative;destination.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(ROOT/source,destination);destination.chmod(mode)
    spec=importlib.util.spec_from_file_location('xsoc_native_inventory',ROOT/'scripts/prepare-native-inventory.py')
    inventory=importlib.util.module_from_spec(spec);spec.loader.exec_module(inventory)
    result=inventory.prepare(stage,args.version,args.target)
    metadata=ROOT/'dist/native-inventory';metadata.mkdir(mode=0o755)
    shutil.copyfile(result,metadata/'linux-inner.cdx.json')


if __name__=='__main__':main()
