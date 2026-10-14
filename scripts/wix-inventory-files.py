#!/usr/bin/env python3
"""Author every actual inventory file into the final MSI without a hand-written subset."""
import argparse
import hashlib
from pathlib import Path
import stat
import uuid
import xml.etree.ElementTree as ET

NAMESPACE='http://wixtoolset.org/schemas/v4/wxs'
ET.register_namespace('',NAMESPACE)


def element(parent,name,**attributes):return ET.SubElement(parent,'{'+NAMESPACE+'}'+name,attributes)


def generate(directory,output,product):
    directory=Path(directory).resolve(strict=True)
    document=ET.Element('{'+NAMESPACE+'}Wix')
    fragment=element(document,'Fragment');root=element(fragment,'DirectoryRef',Id='ReleaseInventoryDirectory')
    group=element(fragment,'ComponentGroup',Id='ReleaseInventoryFiles')
    folders={'':root};count=0
    for path in sorted(directory.rglob('*')):
        info=path.lstat()
        if stat.S_ISDIR(info.st_mode):continue
        if not stat.S_ISREG(info.st_mode) or info.st_nlink!=1 or getattr(info,'st_file_attributes',0)&0x400:
            raise ValueError('MSI inventory must contain physical single-link regular files')
        relative=path.relative_to(directory)
        if any(part in ('','..','.') for part in relative.parts):raise ValueError('invalid MSI inventory path')
        parent=root
        for index,part in enumerate(relative.parts[:-1]):
            name='/'.join(relative.parts[:index+1])
            if name not in folders:
                folders[name]=element(parent,'Directory',Id='InventoryDir_'+hashlib.sha256(name.encode()).hexdigest()[:24],Name=part)
            parent=folders[name]
        name=relative.as_posix();identifier='Inventory_'+hashlib.sha256(name.encode()).hexdigest()[:32]
        component=element(parent,'Component',Id=identifier,Guid=str(uuid.uuid5(uuid.NAMESPACE_URL,'https://github.com/isarmg/'+product+'/inventory/'+name)),Bitness='always64')
        element(component,'File',Id=identifier+'_file',Source=str(path),Name=relative.name,KeyPath='yes')
        element(group,'ComponentRef',Id=identifier);count+=1
    if not count:raise ValueError('final MSI inventory is empty')
    with Path(output).open('xb') as stream:stream.write(ET.tostring(document,encoding='utf-8',xml_declaration=True))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--directory',required=True,type=Path)
    parser.add_argument('--output',required=True,type=Path)
    parser.add_argument('--product',required=True,choices=('xsoc','xscc','xcoc'))
    args=parser.parse_args();generate(args.directory,args.output,args.product)


if __name__=='__main__':main()
