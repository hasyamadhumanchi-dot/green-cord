#!/usr/bin/env python3
"""Validate a content manifest against content/manifest.schema.json and verify
every listed SHA-256 against the file actually on disk. Exits non-zero on failure.

Usage: validate_manifest.py [payload_dir]

No third-party dependencies are available in this environment, so this implements
the subset of JSON Schema draft-07 that manifest.schema.json actually uses:
type, required, additionalProperties, properties, items, enum, pattern,
minimum, maximum, minItems, maxLength.
"""
import hashlib
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
}


def validate(instance, schema, path, errors):
    expected = schema.get("type")
    if expected:
        python_type = TYPES[expected]
        if expected == "integer" and isinstance(instance, bool):
            errors.append(f"{path}: expected integer, got boolean")
            return
        if not isinstance(instance, python_type):
            errors.append(
                f"{path}: expected {expected}, got {type(instance).__name__}"
            )
            return

    if "enum" in schema and instance not in schema["enum"]:
        errors.append(f"{path}: {instance!r} is not one of {schema['enum']}")

    if isinstance(instance, str):
        pattern = schema.get("pattern")
        if pattern and not re.search(pattern, instance):
            errors.append(f"{path}: {instance!r} does not match /{pattern}/")
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            errors.append(f"{path}: longer than maxLength {schema['maxLength']}")

    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "minimum" in schema and instance < schema["minimum"]:
            errors.append(f"{path}: {instance} < minimum {schema['minimum']}")
        if "maximum" in schema and instance > schema["maximum"]:
            errors.append(f"{path}: {instance} > maximum {schema['maximum']}")

    if isinstance(instance, dict):
        for key in schema.get("required", []):
            if key not in instance:
                errors.append(f"{path}: missing required property {key!r}")
        properties = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in instance:
                if key not in properties:
                    errors.append(f"{path}: unexpected property {key!r}")
        for key, subschema in properties.items():
            if key in instance:
                validate(instance[key], subschema, f"{path}.{key}", errors)

    if isinstance(instance, list):
        if "minItems" in schema and len(instance) < schema["minItems"]:
            errors.append(f"{path}: fewer than minItems {schema['minItems']}")
        item_schema = schema.get("items")
        if item_schema:
            for index, item in enumerate(instance):
                validate(item, item_schema, f"{path}[{index}]", errors)


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def locate(payload_dir, name):
    for candidate in (
        os.path.join(payload_dir, name),
        os.path.join(payload_dir, "source", name),
    ):
        if os.path.exists(candidate):
            return candidate
    return None


def main():
    payload_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "content")
    manifest_path = os.path.join(payload_dir, "manifest.json")
    schema_path = os.path.join(ROOT, "content", "manifest.schema.json")

    print(f"manifest: {manifest_path}")
    print(f"schema:   {schema_path}")
    print()

    schema = json.load(open(schema_path))
    try:
        manifest = json.load(open(manifest_path))
    except (OSError, ValueError) as exc:
        print(f"FAIL  cannot read manifest: {exc}")
        return 1

    errors = []
    validate(manifest, schema, "manifest", errors)
    if errors:
        print(f"FAIL  {len(errors)} schema violation(s):")
        for error in errors:
            print(f"        {error}")
        return 1
    print("PASS  manifest conforms to manifest.schema.json")

    ok = True
    print()
    print("  checksum verification")
    print("  " + "-" * 66)
    for entry in manifest["files"]:
        path = locate(payload_dir, entry["name"])
        if path is None:
            print(f"  FAIL  {entry['name']}: file not found under {payload_dir}")
            ok = False
            continue
        actual = sha256(path)
        size = os.path.getsize(path)
        if actual != entry["sha256"]:
            print(f"  FAIL  {entry['name']}: sha256 {actual} != manifest {entry['sha256']}")
            ok = False
        elif size != entry["bytes"]:
            print(f"  FAIL  {entry['name']}: {size} bytes != manifest {entry['bytes']}")
            ok = False
        else:
            print(f"  PASS  {entry['name']:<32} {actual[:16]}...  {size} bytes")

    # The handbook's own contentVersion must agree with the manifest's.
    handbook_path = locate(payload_dir, "handbook.json")
    if handbook_path:
        handbook_version = json.load(open(handbook_path))["contentVersion"]
        if handbook_version != manifest["contentVersion"]:
            print(
                f"  FAIL  handbook.json contentVersion {handbook_version} != "
                f"manifest {manifest['contentVersion']}"
            )
            ok = False
        else:
            print(f"  PASS  contentVersion agrees everywhere: {handbook_version}")

    print()
    if not ok:
        print("MANIFEST VALIDATION FAILED")
        return 1
    print("MANIFEST VALIDATION PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
