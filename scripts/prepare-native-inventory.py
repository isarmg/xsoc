#!/usr/bin/env python3
"""Inventory the actual native XSOC payload before the platform packager."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
# The upstream archive is reviewed independently of every locally built binary.
SOURCE_SHA='690b83ca331378da9ea0d9d61008c4b22dde391387b9bbad7f29387f2595f76e'
SETUP_SHA='896337fcc253220614cf8cdbd5cf2321c5aa326a37a04160a672a281e6104c70'
UPSTREAM='https://github.com/smartmontools/smartmontools/releases/download/RELEASE_7_5/'


def module():
    spec=importlib.util.spec_from_file_location('xsoc_release_inventory',ROOT/'scripts/release-inventory.py')
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value)
    return value


def prepare(stage,version,target,smart_origin=None,*,components=(),build_input_root=None):
    inventory=module();stage=Path(stage).resolve(strict=True)
    revision=inventory.run(['git','rev-parse','HEAD'],ROOT,inventory.clean_environment())
    if target.endswith('windows-msvc'):
        runtime=['xsoc.exe','installer-binaries/XsocMaintenance.exe'];folder='share'
        paths=['smartmontools/bin/smartctl.exe','smartmontools/bin/drivedb.h',
               'smartmontools/COPYING.txt','smartmontools/smartmontools-7.5-source.tar.gz','smartmontools/NOTICE.txt']
        license_path='smartmontools/COPYING.txt'
        if smart_origin is None or hashlib.sha256(Path(smart_origin).read_bytes()).hexdigest()!=SETUP_SHA:
            raise ValueError('Windows smartmontools must match the exact upstream extraction source')
        source={'url':UPSTREAM+'smartmontools-7.5.win32-setup.exe','sha256':SETUP_SHA}
    elif target.endswith('apple-darwin'):
        runtime=['usr/local/libexec/xsoc'];folder='usr/local/share/xsoc'
        paths=['usr/local/libexec/xsoc-smartmontools/bin/smartctl',
               'usr/local/libexec/xsoc-smartmontools/share/drivedb.h',
               *[folder+'/smartmontools/'+name for name in ('COPYING','smartmontools-7.5.tar.gz','build-smartmontools.sh','BUILD-INFO.txt')]]
        license_path=folder+'/smartmontools/COPYING'
        source={'url':UPSTREAM+'smartmontools-7.5.tar.gz','sha256':SOURCE_SHA}
    else:
        runtime=['usr/bin/xsoc'];folder='usr/share/doc/xsoc'
        paths=[];license_path=None
        source={'url':'https://www.smartmontools.org/','sha256':None}
    if paths:
        source_path=stage/('smartmontools/smartmontools-7.5-source.tar.gz' if target.endswith('windows-msvc') else folder+'/smartmontools/smartmontools-7.5.tar.gz')
        if hashlib.sha256(source_path.read_bytes()).hexdigest()!=SOURCE_SHA:
            raise ValueError('bundled smartmontools corresponding source differs from the reviewed archive')
        component={'ref':'pkg:generic/smartmontools@7.5','type':'application','name':'smartmontools','version':'7.5',
                   'source':source,'licenses':[{'name':'GPL-2.0-or-later','path':license_path,
                     'sha256':hashlib.sha256((stage/license_path).read_bytes()).hexdigest()}],
                   'delivery':'file','files':[inventory.file_binding(stage,{'path':path,'archive_entry':None}) for path in paths],
                   'dependencies':[]}
    else:
        component={'ref':'urn:platform:smartmontools','type':'application','name':'smartmontools','version':None,
                   'source':source,'licenses':[],'delivery':'platform','files':[],'dependencies':[]}
    return inventory.generate(stage,product='xsoc',version=version,revision=revision,target=target,root_name='xsoc',
        runtime_files=[{'path':path,'archive_entry':None} for path in runtime],components=[component,*components],
        inventory_relative=folder,output_relative=folder+'/release-sbom.cdx.json',package_symlinks=True,
        build_input_root=build_input_root)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage',required=True,type=Path)
    parser.add_argument('--version',required=True)
    parser.add_argument('--target',required=True)
    parser.add_argument('--smart-origin',type=Path)
    parser.add_argument('--external-components',type=Path)
    parser.add_argument('--build-input-root',type=Path)
    args=parser.parse_args();prepare(args.stage,args.version,args.target,args.smart_origin,
        components=json.loads(args.external_components.read_text()) if args.external_components else (),
        build_input_root=args.build_input_root)


if __name__=='__main__':main()
