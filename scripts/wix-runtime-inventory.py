#!/usr/bin/env python3
"""Record actual MSI runtime streams before rebuilding its final inventory."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import xml.etree.ElementTree as ET

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    for name in ('stage','bootstrap-msi','build-input-root','output','project'):
        parser.add_argument('--'+name,required=True,type=Path)
    parser.add_argument('--owned-input',action='append',default=[],type=Path)
    args=parser.parse_args()
    project=args.project.resolve(strict=True)
    if not project.is_relative_to(ROOT) or project.suffix!='.wixproj':
        raise ValueError('native inventory uses only the current product build project')
    document=ET.parse(project).getroot()
    if document.get('Sdk')!='WixToolset.Sdk/4.0.6':
        raise ValueError('native inventory requires the reviewed exact WiX SDK')
    packages=['wixtoolset.sdk']
    for item in document.iter():
        if item.tag.rsplit('}',1)[-1]=='PackageReference':
            if item.get('Version')!='4.0.6':raise ValueError('native extension differs from the reviewed WiX release')
            packages.append(item.get('Include','').lower())
    specification=importlib.util.spec_from_file_location('client_inventory',ROOT/'scripts/release-inventory.py')
    inventory=importlib.util.module_from_spec(specification);specification.loader.exec_module(inventory)
    args.build_input_root.mkdir(mode=0o700,parents=True,exist_ok=False)
    with tempfile.TemporaryDirectory(prefix='client-wix-inventory-') as temporary:
        tools=inventory.checkout_tools(Path(temporary).resolve(strict=True)/'tools',inventory.clean_environment())
        producer=inventory.load_tool('wix_runtime',tools)
        cache=Path(os.environ.get('NUGET_PACKAGES',str(Path.home()/'.nuget/packages')))
        components=producer.stage_runtime(args.stage,args.bootstrap_msi,args.build_input_root,
            cache=cache,owned_inputs=args.owned_input,packages=packages)
    with args.output.open('x') as output:json.dump(components,output,sort_keys=True);output.write('\n')


if __name__=='__main__':main()
