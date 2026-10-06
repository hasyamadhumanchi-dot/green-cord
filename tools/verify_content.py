#!/usr/bin/env python3
"""Verify the generated content against the source PDF. Exits non-zero on any failure.

Checks (gates A2 and A3):
  1. handbook-outline.md section count == headings detected in the raw extraction
     == sections in handbook.json.
  2. Every handbook.json section maps to a real PDF page index, and every block's
     page index is inside that section's range.
  3. Every entry in the PDF's own Table of Contents (page 2) appears in the outline
     at the page the Table of Contents states. This is an independent cross-check:
     the TOC was written by the handbook's authors, not by our heading rule.
  4. Every `page` cited in requirements.json is a real page, and every `quote`
     appears on that page's extracted text.
  5. Prints the grade -> threshold -> cited page table.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
failures = []

# The handbook's own table of contents lists these entries on the wrong page.
# Verified by hand against the extracted page text: ELIGIBILITY REQUIREMENTS and
# SERVICE HOUR REQUIREMENTS are both listed as page 5, but SERVICE HOUR
# REQUIREMENTS actually begins on page 6. This is an error in the source PDF,
# not in the extraction, so it is reported rather than silently corrected.
SOURCE_TOC_ERRATA = {"service hour requirements"}


def check(ok, message):
    print(("  PASS  " if ok else "  FAIL  ") + message)
    if not ok:
        failures.append(message)


def normalise(text):
    return " ".join(text.split())


def loose(text):
    """Collapse whitespace and punctuation variants so PDF line breaks don't matter."""
    text = normalise(text).lower()
    text = text.replace("’", "'").replace("‘", "'")
    text = text.replace("“", '"').replace("”", '"')
    text = text.replace("–", "-").replace("—", "-")
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


def main():
    raw = json.load(open(os.path.join(ROOT, ".build", "raw.json")))
    pages = raw["pages"]
    page_count = raw["pageCount"]
    page_text = [loose(p["text"]) for p in pages]

    handbook = json.load(open(os.path.join(ROOT, "content", "handbook.json")))
    requirements = json.load(open(os.path.join(ROOT, "content", "requirements.json")))
    outline = open(os.path.join(ROOT, "content", "handbook-outline.md")).read()

    print("=" * 70)
    print("A2 - handbook outline and reflowed sections")
    print("=" * 70)

    # 1. counts
    sys.path.insert(0, os.path.join(ROOT, "tools"))
    import build_content

    headings = build_content.collect_headings(pages)
    outline_rows = re.findall(r"^\| (\d+) \| (.+?) \| (.+?) \| `(.+?)` \|$", outline, re.M)
    print(f"  headings in raw extraction : {len(headings)}")
    print(f"  rows in handbook-outline.md: {len(outline_rows)}")
    print(f"  sections in handbook.json  : {len(handbook['sections'])}")
    check(
        len(headings) == len(outline_rows) == len(handbook["sections"]),
        f"section counts agree ({len(headings)})",
    )
    check(handbook["pageCount"] == page_count, f"handbook.json pageCount == {page_count}")

    # 2. page mapping
    bad_pages = []
    for section in handbook["sections"]:
        if not (0 <= section["startPage"] < page_count and 0 <= section["endPage"] < page_count):
            bad_pages.append(f"{section['id']} range {section['startPage']}-{section['endPage']}")
        for block in section["blocks"]:
            if not 0 <= block["page"] < page_count:
                bad_pages.append(f"{section['id']} block page {block['page']}")
            elif not section["startPage"] <= block["page"] <= section["endPage"]:
                bad_pages.append(f"{section['id']} block page {block['page']} outside range")
    check(not bad_pages, f"every section and block maps to a real PDF page ({bad_pages[:3]})")

    # every section has content, except the two front-matter pages which are
    # a title page and the table of contents
    empty = [s["id"] for s in handbook["sections"] if not s["blocks"]]
    check(not empty, f"every section has reflowed blocks (empty: {empty})")

    # titles in outline match handbook.json
    outline_titles = [normalise(r[1]) for r in outline_rows]
    json_titles = [normalise(s["title"]) for s in handbook["sections"]]
    check(outline_titles == json_titles, "outline titles == handbook.json titles, in order")

    # 3. independent cross-check against the PDF's own table of contents
    print()
    print("  Cross-check: PDF table of contents (page 2) vs generated outline")
    toc_raw = pages[1]["text"]
    toc_entries = re.findall(r"^(.+?)\.{3,}\s*(\d+)\s*$", toc_raw, re.M)
    check(len(toc_entries) > 0, f"table of contents parsed ({len(toc_entries)} entries)")
    by_title = {loose(s["title"]): s for s in handbook["sections"]}
    missing = []
    misplaced = []
    errata = []
    for title, page_no in toc_entries:
        section = by_title.get(loose(title))
        if section is None:
            missing.append(title.strip())
            continue
        stated = int(page_no)
        if not section["startPage"] + 1 <= stated <= section["endPage"] + 1:
            note = (
                f"{title.strip()}: table of contents says page {stated}, "
                f"the heading is on page {section['startPage'] + 1}"
            )
            if loose(title) in SOURCE_TOC_ERRATA:
                errata.append(note)
            else:
                misplaced.append(note)
    for title, page_no in toc_entries:
        section = by_title.get(loose(title))
        actual = section["startPage"] + 1 if section else "?"
        flag = "  <- source erratum" if any(title.strip() in e for e in errata) else ""
        print(f"    TOC p{int(page_no):<3} (actual p{actual:<3}) {title.strip()}{flag}")
    check(not missing, f"every TOC entry exists in the outline (missing: {missing})")
    check(
        not misplaced,
        f"every TOC entry's page matches the outline, apart from known source errata "
        f"(unexpected: {misplaced})",
    )
    if errata:
        print()
        print("  Known errata in the handbook's own table of contents (reported, not")
        print("  corrected -- the app navigates to the page the heading is really on):")
        for note in errata:
            print(f"    * {note}")

    print()
    print("=" * 70)
    print("A3 - requirements extracted from the handbook, with page citations")
    print("=" * 70)

    cited = []

    def walk(node, path):
        if isinstance(node, dict):
            if "page" in node and isinstance(node["page"], int):
                cited.append((path, node["page"], node.get("quote")))
            for key, value in node.items():
                walk(value, f"{path}.{key}")
        elif isinstance(node, list):
            for index, value in enumerate(node):
                walk(value, f"{path}[{index}]")

    walk(requirements, "requirements")
    check(len(cited) > 0, f"requirements.json carries page citations ({len(cited)})")

    bad_page = [f"{p} -> page {n}" for p, n, _ in cited if not 1 <= n <= page_count]
    check(not bad_page, f"every cited page is a real page 1..{page_count} ({bad_page[:3]})")

    bad_quote = []
    for path, page_no, quote in cited:
        if not quote:
            continue
        if loose(quote) not in page_text[page_no - 1]:
            bad_quote.append(f"{path} (page {page_no})")
    check(not bad_quote, f"every quote appears on its cited page ({bad_quote[:3]})")

    print()
    print("  Grade -> threshold -> deadline -> cited page")
    print("  " + "-" * 62)
    print(f"  {'Grade':<7} {'Label':<11} {'Threshold':<10} {'Deadline':<10} {'Pages'}")
    grades = requirements["grades"]
    for g in grades:
        print(
            f"  {g['grade']:<7} {g['label']:<11} "
            f"{str(g['thresholdHours']['value']) + ' h':<10} "
            f"{g['submissionDeadline']['value']:<10} "
            f"hours p{g['thresholdHours']['page']}, deadline p{g['submissionDeadline']['page']}"
        )
    check(
        sorted(g["grade"] for g in grades) == [9, 10, 11, 12],
        "requirements.json has a distinct entry for each of grades 9, 10, 11, 12",
    )
    thresholds = [g["thresholdHours"]["value"] for g in grades]
    check(
        len(set(thresholds)) == 4,
        f"the handbook states a DIFFERENT threshold per grade: {thresholds}",
    )

    print()
    print("  Text of every page cited by requirements.json")
    print("  " + "-" * 62)
    for page_no in sorted({n for _, n, _ in cited}):
        print(f"\n  ----- PDF page {page_no} -----")
        for line in pages[page_no - 1]["text"].split("\n"):
            if line.strip():
                print("    " + line.strip())

    print()
    print("  Items the handbook does not state (surfaced as \"unspecified\")")
    print("  " + "-" * 62)
    for item in requirements["unspecified"]:
        print(f"    {item['field']}  (see page {item['page']})")
        print(f"      {item['reason']}")

    print()
    if failures:
        print(f"FAILED: {len(failures)} check(s)")
        for f in failures:
            print(f"  - {f}")
        return 1
    print("ALL CONTENT CHECKS PASSED")
    return 0


if __name__ == "__main__":
    sys.exit(main())
