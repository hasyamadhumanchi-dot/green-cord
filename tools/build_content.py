#!/usr/bin/env python3
"""Build the bundled handbook content from the source PDF.

Reads the raw PDFKit extraction (tools/extract_pdf.swift output) and produces:
  content/handbook-outline.md  -- every heading with its page range
  content/handbook.json        -- reflowed section text keyed by section id + source page

Heading rule (purely mechanical, applied to the PDFKit attributed-string runs):
  a run is a heading when its font is bold AND its point size is >= 18.
  On the cover page only the single largest run counts, so the cover subtitle
  ("Princeton Senior High School") is body text of the Cover section, not a heading.

Cross-check: every entry in the PDF's own Table of Contents (page 2) must appear
in the generated outline at the page the TOC states. Reported by verify_content.py.
"""
import json
import os
import re
import sys

HEADING_MIN_SIZE = 18.0
SUBHEADING_MIN_SIZE = 12.5
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Text that repeats on every page and is not part of any section body.
FOOTER_RE = re.compile(r"^Updated as of\s+\S+\s+\d+$")


def slugify(title):
    s = title.lower()
    s = re.sub(r"[^a-z0-9]+", "-", s)
    return s.strip("-")


def is_bold(font):
    return "Bold" in font


def normalise(text):
    return " ".join(text.split())


def collect_headings(pages):
    """Return [(page_index, heading_text)] in document order."""
    headings = []
    for page in pages:
        runs = [r for r in page["runs"] if normalise(r["t"])]
        if not runs:
            continue
        if page["index"] == 0:
            biggest = max(runs, key=lambda r: r["size"])
            if is_bold(biggest["font"]):
                headings.append((page["index"], normalise(biggest["t"])))
            continue
        for run in runs:
            if run["size"] >= HEADING_MIN_SIZE and is_bold(run["font"]):
                headings.append((page["index"], normalise(run["t"])))
    return headings


def collect_subheadings(pages):
    """Bold runs smaller than a heading but larger than body text, per page index."""
    found = {}
    for page in pages:
        if page["index"] == 0:
            continue
        for run in page["runs"]:
            text = normalise(run["t"])
            if not text:
                continue
            if SUBHEADING_MIN_SIZE <= run["size"] < HEADING_MIN_SIZE and is_bold(run["font"]):
                found.setdefault(page["index"], []).append(text)
    return found


def split_page_lines(page):
    lines = []
    for raw in page["text"].split("\n"):
        line = raw.rstrip()
        if not line.strip():
            continue
        if FOOTER_RE.match(line.strip()):
            continue
        lines.append(line.strip())
    return lines


def build_sections(pages, headings, subheadings):
    """Slice page text into sections. A section runs from its heading to the next."""
    # Map (page_index, normalised-heading) -> order, so we can find boundaries in text.
    by_page = {}
    for page_index, title in headings:
        by_page.setdefault(page_index, []).append(title)

    sections = []
    for order, (page_index, title) in enumerate(headings):
        end_page = headings[order + 1][0] if order + 1 < len(headings) else len(pages) - 1
        sections.append(
            {
                "id": slugify(title),
                "title": title,
                "order": order,
                "startPage": page_index,
                "endPage": end_page,
                "paragraphs": [],
            }
        )

    # Walk every page's lines, assigning each line to the currently open section.
    current = -1
    heading_lookup = {}
    for order, (page_index, title) in enumerate(headings):
        heading_lookup.setdefault(page_index, []).append((order, title))

    for page in pages:
        lines = split_page_lines(page)
        pending = list(heading_lookup.get(page["index"], []))
        # A heading in the PDF text may be wrapped across several lines; match by
        # accumulating lines until they equal the heading text.
        i = 0
        while i < len(lines):
            matched = False
            if pending:
                order, title = pending[0]
                for span in (1, 2, 3, 4, 5):
                    if i + span > len(lines):
                        break
                    candidate = normalise(" ".join(lines[i : i + span]))
                    if candidate.upper() == title.upper():
                        current = order
                        pending.pop(0)
                        i += span
                        matched = True
                        break
            if matched:
                continue

            subs = subheadings.get(page["index"], [])
            sub_span = 0
            for span in (1, 2, 3):
                if i + span > len(lines):
                    break
                candidate = normalise(" ".join(lines[i : i + span]))
                if any(candidate == s for s in subs):
                    sub_span = span
                    break
            if sub_span and current >= 0:
                sections[current]["paragraphs"].append(
                    {
                        "text": normalise(" ".join(lines[i : i + sub_span])),
                        "page": page["index"],
                        "sub": True,
                    }
                )
                i += sub_span
                continue

            if current >= 0:
                sections[current]["paragraphs"].append(
                    {"text": lines[i], "page": page["index"]}
                )
            i += 1

    for section in sections:
        pages_used = sorted({p["page"] for p in section["paragraphs"]})
        if pages_used:
            section["startPage"] = min(section["startPage"], pages_used[0])
            section["endPage"] = max(pages_used)
        else:
            section["endPage"] = section["startPage"]
    return sections


def render_paragraphs(section):
    """Group consecutive lines into paragraphs / bullets, keeping the source page."""
    blocks = []
    buffer_lines = []
    buffer_page = None

    def flush():
        nonlocal buffer_lines, buffer_page
        if buffer_lines:
            blocks.append(
                {"kind": "paragraph", "text": " ".join(buffer_lines), "page": buffer_page}
            )
            buffer_lines = []
            buffer_page = None

    for item in section["paragraphs"]:
        line = item["text"]
        if item.get("sub"):
            flush()
            blocks.append({"kind": "subheading", "text": line, "page": item["page"]})
            continue
        bullet = line.startswith(("•", "●", "✓", "○", "-")) or line in ("●", "•")
        if bullet:
            flush()
            text = line.lstrip("•●✓○- ").strip()
            if text:
                blocks.append({"kind": "bullet", "text": text, "page": item["page"]})
            else:
                # A bare bullet glyph on its own line: the PDF puts the marker column
                # separate from the text column. Remember it so the next plain line
                # becomes a bullet instead of a paragraph.
                blocks.append({"kind": "orphan-bullet", "text": "", "page": item["page"]})
            continue
        if blocks and blocks[-1]["kind"] == "orphan-bullet":
            blocks[-1] = {"kind": "bullet", "text": line, "page": item["page"]}
            continue
        if buffer_page is None:
            buffer_page = item["page"]
        buffer_lines.append(line)
        if line.endswith((".", ":", "?", "!")):
            flush()
    flush()
    return [b for b in blocks if b["kind"] != "orphan-bullet" and b["text"]]


def main():
    raw_path = sys.argv[1]
    raw = json.load(open(raw_path))
    pages = raw["pages"]
    page_count = raw["pageCount"]

    headings = collect_headings(pages)
    subheadings = collect_subheadings(pages)
    sections = build_sections(pages, headings, subheadings)

    out_sections = []
    for section in sections:
        blocks = render_paragraphs(section)
        out_sections.append(
            {
                "id": section["id"],
                "title": section["title"],
                "order": section["order"],
                "startPage": section["startPage"],
                "endPage": section["endPage"],
                "blocks": blocks,
                "plainText": " ".join(b["text"] for b in blocks),
            }
        )

    handbook = {
        "schemaVersion": 1,
        "contentVersion": raw.get("contentVersion", "2026.08.21"),
        "sourcePdf": "PISDGreenCordHandbook.pdf",
        "pageCount": page_count,
        "sections": out_sections,
    }

    os.makedirs(os.path.join(ROOT, "content"), exist_ok=True)
    with open(os.path.join(ROOT, "content", "handbook.json"), "w") as fh:
        json.dump(handbook, fh, indent=2, sort_keys=True)
        fh.write("\n")

    lines = [
        "# Princeton ISD Green Cord Handbook - Section Outline",
        "",
        "Generated by `tools/build_content.py` from `content/source/PISDGreenCordHandbook.pdf`.",
        "Heading rule: a PDFKit text run whose font is bold and whose point size is >= 18.",
        "On the cover page only the single largest run counts.",
        "",
        "Pages are 1-based, matching the printed page numbers in the PDF footer.",
        "",
        f"Source page count: {page_count}",
        f"Section count: {len(out_sections)}",
        "",
        "| # | Section | Pages | Section id |",
        "| --- | --- | --- | --- |",
    ]
    for section in out_sections:
        start = section["startPage"] + 1
        end = section["endPage"] + 1
        page_range = str(start) if start == end else f"{start}-{end}"
        lines.append(
            f"| {section['order'] + 1} | {section['title']} | {page_range} | `{section['id']}` |"
        )
    lines.append("")
    with open(os.path.join(ROOT, "content", "handbook-outline.md"), "w") as fh:
        fh.write("\n".join(lines))

    print(f"headings detected from raw extraction: {len(headings)}")
    print(f"sections written to handbook.json:     {len(out_sections)}")
    print(f"outline rows written:                  {len(out_sections)}")
    print(f"pdf page count:                        {page_count}")


if __name__ == "__main__":
    main()
