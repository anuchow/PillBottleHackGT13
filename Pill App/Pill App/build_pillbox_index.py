#!/usr/bin/env python3
"""
Builds pillbox_index.json (the app's offline pill database) from the
Pillbox archived CSV.

1. Go to the Pillbox Archived Data page on datadiscovery.nlm.nih.gov
   and export the full table as CSV.
2. Run:  python3 build_pillbox_index.py pillbox.csv pillbox_index.json
3. Drag pillbox_index.json into Xcode and tick your app target.

Only the columns the app needs are kept, and rows that describe the same
pill appearance are merged, so the output is much smaller than the CSV.
"""
import csv
import json
import os
import re
import sys

OUT_FIELDS = ["name", "strength", "rxstring", "manufacturer",
              "imprint", "colors", "shape", "size", "image"]

EXPECTED = ["splimprint", "splcolor_text", "splshape_text", "spl_strength"]


def norm_key(key):
    return key.strip().lower().replace(" ", "_").replace("?", "")


def first(row, *keys):
    """First non-empty value among several possible column names.
    pillbox_* columns are NLM's corrections from photos, so they win."""
    for key in keys:
        value = (row.get(key) or "").strip()
        if value:
            return value
    return ""


def main(src, dst):
    csv.field_size_limit(sys.maxsize)
    with open(src, newline="", encoding="utf-8-sig") as f:
        reader = csv.DictReader(f)
        reader.fieldnames = [norm_key(k) for k in reader.fieldnames]

        missing = [c for c in EXPECTED if c not in reader.fieldnames]
        if missing:
            print("WARNING: expected columns not found:", missing)
            print("Columns in this file:", reader.fieldnames)

        seen = set()
        rows = []
        read = 0
        for row in reader:
            read += 1
            name = first(row, "medicine_name", "title", "rxstring")
            imprint = first(row, "pillbox_imprint", "splimprint").upper()
            colors = first(row, "pillbox_color_text", "splcolor_text").upper()
            colors = re.sub(r"\s*[,;]\s*", ";", colors)
            shape = first(row, "pillbox_shape_text", "splshape_text").upper()
            if not name or not (imprint or colors or shape):
                continue

            size_raw = first(row, "pillbox_size", "splsize")
            size_match = re.search(r"\d+(\.\d+)?", size_raw)

            record = [
                name,
                first(row, "spl_strength"),
                first(row, "rxstring"),
                first(row, "author", "labeler"),
                imprint,
                colors,
                shape,
                size_match.group(0) if size_match else "",
                first(row, "image_id", "splimage"),
            ]
            key = tuple(record[:8])      # ignore image when de-duplicating
            if key in seen:
                continue
            seen.add(key)
            rows.append(record)

    with open(dst, "w", encoding="utf-8") as f:
        json.dump({"fields": OUT_FIELDS, "rows": rows}, f, separators=(",", ":"))

    size_mb = os.path.getsize(dst) / 1_000_000
    print(f"Read {read:,} rows, wrote {len(rows):,} unique pill appearances ({size_mb:.1f} MB) to {dst}")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        sys.exit("usage: python3 build_pillbox_index.py pillbox.csv pillbox_index.json")
    main(sys.argv[1], sys.argv[2])
