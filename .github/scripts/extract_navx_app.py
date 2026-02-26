#!/usr/bin/env python3
"""Extract a BC .app file (NavX format) to a folder.

BC .app files consist of a 40-byte binary header followed by a ZIP payload.
The ZIP contains AL source files and NavxManifest.xml (the app manifest).

This script extracts the ZIP payload and generates app.json from the manifest,
replacing BcContainerHelper's Extract-AppFileToFolder -generateAppJson cmdlet.

NavX header layout (40 bytes):
  - uint32 magic1 (0x5856414E)
  - uint32 metadataSize
  - uint32 metadataVersion
  - byte[16] packageId (GUID)
  - int64 contentLength
  - uint32 magic2 (0x5856414E)

Usage: extract_navx_app.py <app_file> <output_dir>
"""

import sys
import os
import zipfile
import io
import json
import xml.etree.ElementTree as ET


def parse_navx_manifest(manifest_path):
    """Parse NavxManifest.xml and return an app.json-compatible dict."""
    tree = ET.parse(manifest_path)
    root = tree.getroot()

    # Handle XML namespace if present
    ns = ''
    if root.tag.startswith('{'):
        ns = root.tag[:root.tag.index('}') + 1]

    app_node = root.find(f'{ns}App')
    if app_node is None:
        app_node = root

    manifest = {}

    # Core metadata
    for attr in ('Id', 'Name', 'Publisher', 'Version', 'Brief', 'Description',
                 'Platform', 'Application', 'Runtime', 'Target',
                 'ShowMyCode', 'ApplicationInsightsKey',
                 'ApplicationInsightsConnectionString'):
        val = app_node.get(attr)
        if val is not None:
            # Convert attribute names to camelCase for app.json
            key = attr[0].lower() + attr[1:]
            manifest[key] = val

    # Resource exposure policy
    rep_node = app_node.find(f'{ns}ResourceExposurePolicy')
    if rep_node is not None:
        policy = {}
        for attr in ('allowDebugging', 'allowDownloadingSource',
                     'includeSourceInSymbolFile', 'applyToDevExtension'):
            val = rep_node.get(attr)
            if val is not None:
                policy[attr] = val.lower() == 'true'
        if policy:
            manifest['resourceExposurePolicy'] = policy

    # Dependencies
    deps_node = app_node.find(f'{ns}Dependencies')
    if deps_node is not None:
        deps = []
        for dep in deps_node:
            dep_dict = {}
            for attr in ('id', 'Id', 'name', 'Name', 'publisher', 'Publisher',
                         'minVersion', 'MinVersion', 'maxVersion', 'MaxVersion'):
                val = dep.get(attr)
                if val is not None:
                    key = attr[0].lower() + attr[1:]
                    dep_dict[key] = val
            if dep_dict:
                deps.append(dep_dict)
        if deps:
            manifest['dependencies'] = deps

    # ID ranges
    idranges_node = app_node.find(f'{ns}IdRanges')
    if idranges_node is not None:
        ranges = []
        for r in idranges_node:
            range_dict = {}
            for attr in ('MinObjectId', 'MaxObjectId', 'minObjectId', 'maxObjectId',
                         'from', 'to', 'From', 'To'):
                val = r.get(attr)
                if val is not None:
                    key = attr[0].lower() + attr[1:]
                    # Normalize to from/to
                    if key == 'minObjectId':
                        key = 'from'
                    elif key == 'maxObjectId':
                        key = 'to'
                    try:
                        range_dict[key] = int(val)
                    except ValueError:
                        range_dict[key] = val
            if range_dict:
                ranges.append(range_dict)
        if ranges:
            manifest['idRanges'] = ranges

    # Features
    features_node = app_node.find(f'{ns}Features')
    if features_node is not None:
        features = []
        for f_node in features_node:
            text = f_node.text or f_node.get('Feature') or f_node.get('Name')
            if text:
                features.append(text)
        if features:
            manifest['features'] = features

    return manifest


def generate_app_json_from_filename(app_file, output_dir):
    """Last-resort: construct minimal app.json from the .app filename pattern.

    Filenames follow: Publisher_Name_Version.app
    e.g., Microsoft_Base Application_26.5.38752.46757.app
    """
    basename = os.path.splitext(os.path.basename(app_file))[0]
    parts = basename.split('_', 2)  # Split into at most 3 parts
    if len(parts) >= 3:
        publisher = parts[0]
        # Last part contains version
        name_and_version = parts[1] if len(parts) == 2 else '_'.join(parts[1:])
        # Try to extract version from the end
        segments = name_and_version.rsplit('_', 1)
        if len(segments) == 2:
            name, version = segments
        else:
            name = name_and_version
            version = "0.0.0.0"
    else:
        publisher = "Unknown"
        name = basename
        version = "0.0.0.0"

    manifest = {
        "id": "00000000-0000-0000-0000-000000000000",
        "name": name,
        "publisher": publisher,
        "version": version,
        "runtime": "14.0"
    }

    app_json_path = os.path.join(output_dir, 'app.json')
    with open(app_json_path, 'w', encoding='utf-8') as f:
        json.dump(manifest, f, indent=2)
    print(f"  Generated app.json from filename (fallback)")
    return True


def main():
    if len(sys.argv) != 3:
        print("Usage: extract_navx_app.py <app_file> <output_dir>")
        sys.exit(1)

    app_file = sys.argv[1]
    output_dir = sys.argv[2]

    with open(app_file, 'rb') as f:
        data = f.read()

    # Find ZIP payload by scanning for local file header signature (PK\x03\x04)
    zip_start = data.find(b'\x50\x4b\x03\x04')
    if zip_start == -1:
        print(f"ERROR: No ZIP payload found in {os.path.basename(app_file)}")
        sys.exit(1)

    zip_data = data[zip_start:]
    os.makedirs(output_dir, exist_ok=True)

    try:
        with zipfile.ZipFile(io.BytesIO(zip_data)) as zf:
            zf.extractall(output_dir)
    except zipfile.BadZipFile:
        print(f"ERROR: Invalid ZIP payload in {os.path.basename(app_file)}")
        sys.exit(1)

    app_json_path = os.path.join(output_dir, 'app.json')

    # app.json already in ZIP — nothing to do
    if os.path.exists(app_json_path):
        return

    # Generate app.json from NavxManifest.xml (the standard manifest location)
    manifest_path = os.path.join(output_dir, 'NavxManifest.xml')
    if os.path.exists(manifest_path):
        try:
            manifest = parse_navx_manifest(manifest_path)
            if manifest:
                with open(app_json_path, 'w', encoding='utf-8') as f:
                    json.dump(manifest, f, indent=2)
                return
        except Exception as e:
            print(f"  WARNING: Failed to parse NavxManifest.xml: {e}")

    # Last resort: generate minimal app.json from filename
    generate_app_json_from_filename(app_file, output_dir)


if __name__ == '__main__':
    main()
