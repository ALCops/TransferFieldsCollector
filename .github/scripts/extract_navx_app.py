#!/usr/bin/env python3
"""Extract a BC .app file (NavX format) to a folder.

BC .app files consist of a binary header (containing the app manifest)
followed by a ZIP payload (containing AL source files and typically app.json).

This script finds the ZIP payload and extracts it, replacing
BcContainerHelper's Extract-AppFileToFolder cmdlet.

Usage: extract_navx_app.py <app_file> <output_dir>
"""

import sys
import os
import zipfile
import io
import json


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

    # If app.json not in ZIP, try to extract manifest from NavX header
    app_json_path = os.path.join(output_dir, 'app.json')
    if not os.path.exists(app_json_path):
        header = data[:zip_start]
        # The NavX header contains the app manifest as JSON between { and }
        json_start = header.find(b'{')
        json_end = header.rfind(b'}')
        if json_start != -1 and json_end > json_start:
            try:
                candidate = header[json_start:json_end + 1].decode('utf-8')
                manifest = json.loads(candidate)
                # Validate it looks like an app manifest
                if 'id' in manifest or 'name' in manifest:
                    with open(app_json_path, 'w', encoding='utf-8') as f:
                        json.dump(manifest, f, indent=2)
                    print(f"  Generated app.json from NavX header")
            except (json.JSONDecodeError, UnicodeDecodeError):
                pass


if __name__ == '__main__':
    main()
