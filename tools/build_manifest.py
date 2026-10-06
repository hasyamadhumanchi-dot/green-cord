#!/usr/bin/env python3
"""Write content/manifest.json from the files actually on disk.

Usage: build_manifest.py [payload_dir] [--base-url URL]

payload_dir defaults to content/, so the manifest checked into the repo describes
the repo's own files. tools/publish-content.sh calls it again against the staged
upload directory so the published manifest describes exactly what is uploaded.
"""
import argparse
import datetime
import hashlib
import json
import os

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BASE_URL = "https://pshs.princetonisd.net/greencord-app-content/"

PAYLOAD = [
    ("handbook", "handbook.json"),
    ("requirements", "requirements.json"),
    ("pdf", "PISDGreenCordHandbook.pdf"),
]


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def locate(payload_dir, name):
    """The PDF lives under source/ in the repo but at the top level once staged."""
    direct = os.path.join(payload_dir, name)
    if os.path.exists(direct):
        return direct
    nested = os.path.join(payload_dir, "source", name)
    if os.path.exists(nested):
        return nested
    raise SystemExit(f"missing payload file: {name} (looked in {payload_dir})")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("payload_dir", nargs="?", default=os.path.join(ROOT, "content"))
    parser.add_argument("--base-url", default=DEFAULT_BASE_URL)
    parser.add_argument("--out")
    args = parser.parse_args()

    base_url = args.base_url if args.base_url.endswith("/") else args.base_url + "/"
    out_path = args.out or os.path.join(args.payload_dir, "manifest.json")

    handbook = json.load(open(locate(args.payload_dir, "handbook.json")))
    content_version = handbook["contentVersion"]

    files = []
    for role, name in PAYLOAD:
        path = locate(args.payload_dir, name)
        files.append(
            {
                "role": role,
                "name": name,
                "url": base_url + name,
                "sha256": sha256(path),
                "bytes": os.path.getsize(path),
            }
        )

    manifest = {
        "schemaVersion": 1,
        "contentVersion": content_version,
        "publishedAt": datetime.datetime.now(datetime.timezone.utc).strftime(
            "%Y-%m-%dT%H:%M:%SZ"
        ),
        "notes": "Princeton ISD Green Cord handbook content. Data only - no executable code.",
        "files": files,
    }

    with open(out_path, "w") as fh:
        json.dump(manifest, fh, indent=2)
        fh.write("\n")
    print(f"wrote {out_path}  contentVersion={content_version}  files={len(files)}")


if __name__ == "__main__":
    main()
