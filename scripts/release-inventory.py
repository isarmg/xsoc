#!/usr/bin/env python3
"""Bind the actual release runtime graph to its final staged native files."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import zipfile

ROOT = Path(__file__).resolve().parents[1]
TOOLS_REPOSITORY = 'https://github.com/isarmg/xssi.git'


def clean_environment():
    return {key: value for key, value in os.environ.items()
            if not any(part in key.upper() for part in ('SIGNING', 'PASSWORD', 'PRIVATE_KEY', 'TOKEN', 'SECRET'))}


def run(command, cwd, environment):
    return subprocess.check_output(command, cwd=cwd, env=environment,
                                   stdin=subprocess.DEVNULL, timeout=1800).decode().strip()


def tools_identity():
    identity = json.loads((ROOT / 'build-tools-source.json').read_text(encoding='utf-8'))
    if set(identity) != {'repository', 'revision'} or identity['repository'] != TOOLS_REPOSITORY or not isinstance(identity['revision'], str) or not re.fullmatch('[0-9a-f]{40}', identity['revision']):
        raise ValueError('release build tools require their exact official Git revision')
    return identity


def checkout_tools(destination, environment):
    identity = tools_identity()
    run(['git', 'init', '--quiet', str(destination)], ROOT, environment)
    run(['git', 'remote', 'add', 'origin', identity['repository']], destination, environment)
    run(['git', '-c', 'credential.helper=', '-c', 'core.hooksPath=/dev/null',
         'fetch', '--depth=1', 'origin', identity['revision']], destination, environment)
    run(['git', '-c', 'core.hooksPath=/dev/null', 'checkout', '--quiet', '--detach', 'FETCH_HEAD'], destination, environment)
    if run(['git', 'rev-parse', 'HEAD'], destination, environment) != identity['revision']:
        raise ValueError('release tools checkout differs from its immutable source')
    return destination


def exported_source(destination, revision, environment):
    if not re.fullmatch('[0-9a-f]{40}', revision) or run(['git', 'rev-parse', 'HEAD'], ROOT, environment) != revision or run(['git', 'status', '--porcelain', '--untracked-files=all'], ROOT, environment):
        raise ValueError('runtime inventory requires the exact clean compiled source')
    archive = destination.parent / 'source.tar'
    run(['git', '-c', 'core.autocrlf=false', 'archive', '--format=tar', '--output', str(archive), revision], ROOT, environment)
    destination.mkdir(mode=0o700)
    with tarfile.open(archive) as source:
        for entry in source:
            path = PurePosixPath(entry.name)
            if path.is_absolute() or '..' in path.parts or not (entry.isdir() or entry.isfile()):
                raise ValueError('release source export contains an uncontrolled path')
            source.extract(entry, destination, filter='data')
    archive.unlink()
    return destination


def load_tool(name, directory):
    spec = importlib.util.spec_from_file_location('xssi_release_' + name, directory / 'scripts' / (name + '.py'))
    module = importlib.util.module_from_spec(spec)
    sys.path.insert(0, str(directory / 'scripts'))
    try:
        spec.loader.exec_module(module)
    finally:
        sys.path.pop(0)
    return module


def file_binding(stage, value):
    if set(value) != {'path', 'archive_entry'}:
        raise ValueError('runtime file binding differs from its current contract')
    path = PurePosixPath(value['path'])
    if path.is_absolute() or str(path) != value['path'] or '..' in path.parts or '\\' in value['path']:
        raise ValueError('runtime file binding must stay within the release stage')
    item = dict(value)
    if item['archive_entry'] is None:
        with (stage / str(path)).open('rb') as source:
            item['sha256'] = hashlib.file_digest(source, 'sha256').hexdigest()
    else:
        entry = PurePosixPath(item['archive_entry'])
        if entry.is_absolute() or str(entry) != item['archive_entry'] or '..' in entry.parts or '\\' in item['archive_entry']:
            raise ValueError('runtime archive entry must be canonical')
        with zipfile.ZipFile(stage / str(path)) as archive:
            with archive.open(item['archive_entry']) as source:
                item['sha256'] = hashlib.file_digest(source, 'sha256').hexdigest()
    return item


def generate(stage, *, product, version, revision, target, root_name,
             runtime_files, features=(), default_features=True,
             components=(), build_input_root=None, manifest_relative='Cargo.toml',
             package_symlinks=False, additional_runtime_graphs=(),
             inventory_relative='share', output_relative='share/release-sbom.cdx.json'):
    """Generate before the platform package/signature, with its real build options."""
    stage = Path(stage).resolve(strict=True)
    environment = clean_environment()
    (stage / 'share').mkdir(mode=0o755, exist_ok=True)
    (stage / 'share').chmod(0o755)
    with tempfile.TemporaryDirectory(prefix=product + '-release-inventory-') as temporary:
        private = Path(temporary).resolve(strict=True)
        tools = checkout_tools(private / 'tools', environment)
        source = exported_source(private / 'source', revision, environment)
        producer = load_tool('sbom', tools)
        finalizer = load_tool('release_sbom', tools)
        manifest = PurePosixPath(manifest_relative)
        if manifest.is_absolute() or str(manifest) != manifest_relative or '..' in manifest.parts or '\\' in manifest_relative:
            raise ValueError('release Cargo manifest must be within the exported source')
        bom = producer.produce_runtime_cargo_bom(source, source / manifest_relative,
            root_name, stage, 'runtime', [(source, revision)], target=target,
            features=features, default_features=default_features,
            environment=environment)
        runtime_bindings=[file_binding(stage,value) for value in runtime_files]
        all_components=list(components)
        normalized=json.loads(bom.read_text(encoding='utf-8'))
        if any(item.get('name')=='libsqlite3-sys' for item in normalized.get('components',[])):
            native=load_tool('sqlite_receipt',tools)
            all_components.append(native.record(source,stage,'runtime',files=runtime_bindings,
                                                inventory_relative=inventory_relative))
        destination=PurePosixPath(inventory_relative)
        if destination.is_absolute() or str(destination)!=inventory_relative or '..' in destination.parts or '\\' in inventory_relative:
            raise ValueError('native dependency inventory must stay within its actual package layout')
        if inventory_relative!='share':
            folder=stage/inventory_relative;folder.mkdir(mode=0o755,parents=True,exist_ok=True)
            for path in (bom,stage/'share/THIRD_PARTY_RUNTIME_LICENSES.txt'):
                target_path=folder/path.name
                if target_path.exists():raise ValueError('native dependency inventory would replace an existing payload file')
                shutil.move(path,target_path)
            bom=folder/bom.name
            (stage/'share').rmdir()
        root = json.loads(bom.read_text(encoding='utf-8'))['metadata']['component']['bom-ref']
        receipt = {'format_version': 1,
                   'runtime_roots': [{'ref': root, 'files': runtime_bindings}],
                   'components': all_components}
        boms=[bom]
        for graph in additional_runtime_graphs:
            if set(graph)!={'bom','files'}:
                raise ValueError('additional runtime graph differs from its current contract')
            path=Path(graph['bom']).resolve(strict=True)
            if not path.is_relative_to(stage):
                raise ValueError('additional runtime graph must be in the final release stage')
            root=json.loads(path.read_text(encoding='utf-8'))['metadata']['component']['bom-ref']
            boms.append(path)
            receipt['runtime_roots'].append({'ref':root,'files':[
                file_binding(stage,value) for value in graph['files']]})
        receipt_path = private / 'external-components.json'
        receipt_path.write_text(json.dumps(receipt),encoding='utf-8')
        result = finalizer.finalize(stage, boms, receipt_path, product, version,
                                    revision, target, build_input_root=build_input_root,
                                    package_symlinks=package_symlinks,
                                    output_relative=output_relative)
    if run(['git', 'rev-parse', 'HEAD'], ROOT, environment) != revision or run(['git', 'status', '--porcelain', '--untracked-files=all'], ROOT, environment):
        raise ValueError('source changed while computing the release inventory')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--stage', type=Path, required=True)
    parser.add_argument('--product', required=True)
    parser.add_argument('--version', required=True)
    parser.add_argument('--source-revision', required=True)
    parser.add_argument('--target', required=True)
    parser.add_argument('--root-name', required=True)
    parser.add_argument('--manifest', default='Cargo.toml')
    parser.add_argument('--runtime-files', type=Path, required=True)
    parser.add_argument('--external-components', type=Path)
    parser.add_argument('--additional-runtime-graphs', type=Path)
    parser.add_argument('--build-input-root', type=Path)
    parser.add_argument('--features', action='append', default=[])
    parser.add_argument('--no-default-features', action='store_true')
    parser.add_argument('--package-symlinks', action='store_true')
    parser.add_argument('--inventory-relative',default='share')
    parser.add_argument('--output-relative',default='share/release-sbom.cdx.json')
    args = parser.parse_args()
    generate(args.stage, product=args.product, version=args.version,
             revision=args.source_revision, target=args.target, root_name=args.root_name,
             runtime_files=json.loads(args.runtime_files.read_text(encoding='utf-8')),
             features=args.features, default_features=not args.no_default_features,
             components=json.loads(args.external_components.read_text(encoding='utf-8')) if args.external_components else [],
             build_input_root=args.build_input_root, manifest_relative=args.manifest,
             package_symlinks=args.package_symlinks,
             additional_runtime_graphs=json.loads(args.additional_runtime_graphs.read_text(encoding='utf-8')) if args.additional_runtime_graphs else [],
             inventory_relative=args.inventory_relative,output_relative=args.output_relative)


if __name__ == '__main__':
    main()
