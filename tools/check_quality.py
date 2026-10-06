#!/usr/bin/env python3
"""Repository-wide quality gates. Exits non-zero on any violation.

  * No placeholder content (lorem ipsum, TODO, FIXME, PLACEHOLDER).
  * No "Plano" - this is Princeton ISD, and mislabelling the district in an app
    that carries its name is the kind of error that is embarrassing rather than
    merely wrong.
  * No analytics, advertising or tracking SDKs.
  * No committed secrets.
  * No real student names: every name in the seed script is synthetic.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

SKIP_DIRS = {".git", "build", ".build", "DerivedData", "node_modules", "verification",
             # The empty Xcode template that was in the repository before this
             # project. Not part of the app; see README.md.
             "GreenCord.xcodeproj", "GreenCord"}
SKIP_SUFFIXES = (".pdf", ".png", ".jpg", ".jpeg", ".db", ".xcuserstate", ".crt", ".key")

failures = []


def walk():
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = sorted(d for d in dirs if d not in SKIP_DIRS)
        for name in sorted(files):
            path = os.path.join(base, name)
            if path.endswith(SKIP_SUFFIXES):
                continue
            if os.path.getsize(path) > 4_000_000:
                continue
            yield path


def read(path):
    try:
        return open(path, encoding="utf-8", errors="ignore").read()
    except OSError:
        return ""


def check(title, pattern, explain, allow=(), ignore_case=True):
    """Report every line matching `pattern`, except in allow-listed files."""
    regex = re.compile(pattern, re.IGNORECASE if ignore_case else 0)
    hits = []
    for path in walk():
        relative = os.path.relpath(path, ROOT)
        if any(relative == a or relative.startswith(a) for a in allow):
            continue
        for number, line in enumerate(read(path).split("\n"), 1):
            if regex.search(line):
                hits.append(f"{relative}:{number}: {line.strip()[:120]}")
    if hits:
        failures.append((title, explain, hits))
        print(f"  FAIL  {title} ({len(hits)} hit(s))")
        for hit in hits[:8]:
            print(f"          {hit}")
        if len(hits) > 8:
            print(f"          ... and {len(hits) - 8} more")
    else:
        print(f"  PASS  {title}")


def main():
    print("Repository quality gates")
    print("=" * 64)

    # This file names the very strings it looks for, so it is excluded from its
    # own scan. So is the gate report, which quotes them when reporting a result.
    self_referential = ("tools/check_quality.py", "GATES.md")

    # Case-sensitive on purpose. A placeholder *marker* is written in caps;
    # the lower-case word appears in prose that documents a known gap, such as
    # the manifest URL nobody has confirmed yet, and that prose should stay.
    check(
        "No placeholder content",
        r"\blorem ipsum\b|\bTODO\b|\bFIXME\b|\bPLACEHOLDER\b|\bXXX\b|\bHACK\b",
        "Placeholder markers must not ship.",
        allow=self_referential,
        ignore_case=False,
    )
    check(
        "District is Princeton, never Plano",
        r"\bPlano\b",
        "This is Princeton ISD. Mislabelling the district would be a visible error.",
        allow=self_referential,
    )
    check(
        "No analytics, advertising or tracking SDKs",
        r"\b(FirebaseAnalytics|GoogleAnalytics|Crashlytics|Mixpanel|Amplitude|"
        r"Segment(Analytics)?|AppsFlyer|Adjust\.|Branch\.io|Flurry|Bugsnag|"
        r"Sentry|GoogleMobileAds|AdMob|FacebookSDK|FBSDK|AppTrackingTransparency|"
        r"ATTrackingManager|IDFA|advertisingIdentifier)\b",
        "No third-party analytics, advertising or tracking.",
        allow=self_referential,
    )
    check(
        "No committed secrets",
        r"eyJ[A-Za-z0-9_-]{30,}\.[A-Za-z0-9_-]{20,}|sk-[A-Za-z0-9]{32,}|"
        r"service_role|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----",
        "No keys, tokens or private keys in the repository.",
        # The backend suite has its own secret scanner, so it names the same
        # patterns this one does.
        allow=self_referential + ("backend/tests/test_backend.py",),
    )

    # The seed script must only contain invented names. This asserts the
    # positive - that the cohort is the phonetic-alphabet/tree-species set the
    # script documents - rather than trying to guess at real names.
    seed = read(os.path.join(ROOT, "tools", "seed_demo.py"))
    cohort = re.findall(r'\(\s*\d+,\s*"([A-Za-z]+)",\s*"([A-Za-z]+)"', seed)
    phonetic = {
        "Alpha", "Bravo", "Charlie", "Delta", "Echo", "Foxtrot", "Golf",
        "Hotel", "India", "Juliet", "Kilo", "Lima",
    }
    bad = [f"{first} {last}" for first, last in cohort if first not in phonetic]
    if not cohort:
        failures.append(
            ("Seed cohort could not be parsed", "Expected a COHORT table", [])
        )
        print("  FAIL  Demo names are obviously synthetic (cohort not found)")
    elif bad:
        failures.append(
            (
                "Demo names are not obviously synthetic",
                "Every demo first name must come from the phonetic alphabet.",
                bad,
            )
        )
        print(f"  FAIL  Demo names are obviously synthetic: {bad}")
    else:
        print(f"  PASS  Demo names are obviously synthetic ({len(cohort)} students)")

    # No plain-http URL anywhere the app might fetch from.
    http_hits = []
    for path in walk():
        relative = os.path.relpath(path, ROOT)
        if not relative.endswith((".swift", ".json", ".plist", ".xcprivacy")):
            continue
        for number, line in enumerate(read(path).split("\n"), 1):
            for match in re.finditer(r'"http://[^"]+"', line):
                url = match.group(0)
                # Test fixtures deliberately use http:// to prove it is refused.
                if "Tests" in relative:
                    continue
                # XML doctype and JSON Schema identifiers are names, not
                # addresses: nothing dereferences them.
                if any(host in url for host in (
                    "apple.com/DTDs", "json-schema.org", "www.w3.org"
                )):
                    continue
                http_hits.append(f"{relative}:{number}: {url}")
    if http_hits:
        failures.append(("Plain-http URL in shipping code", "HTTPS only.", http_hits))
        print(f"  FAIL  No plain-http URLs in shipping code ({len(http_hits)})")
        for hit in http_hits[:5]:
            print(f"          {hit}")
    else:
        print("  PASS  No plain-http URLs in shipping code")

    # No third-party package manager anywhere.
    dependency_files = [
        f for f in ("Package.swift", "Podfile", "Cartfile", "package.json")
        if os.path.exists(os.path.join(ROOT, f))
    ]
    if dependency_files:
        failures.append(
            ("Third-party dependencies present", "The app has no dependencies.",
             dependency_files)
        )
        print(f"  FAIL  No third-party dependency manifests ({dependency_files})")
    else:
        print("  PASS  No third-party dependency manifests")

    print()
    if failures:
        print(f"{len(failures)} quality gate(s) failed")
        return 1
    print("All quality gates passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
