#!/usr/bin/env python3
"""
Scrape farming-simulator.com for FS25 map mods rated 4.5 stars or more.
Produces a list of mod filenames and descriptions for weather profile estimation.

Usage:
    python scrape_maps.py                        # all regions, fetch detail pages
    python scrape_maps.py --region mapEurope     # single region
    python scrape_maps.py --output maps.json     # write JSON instead of stdout
    python scrape_maps.py --no-detail            # skip detail fetches (faster, no description/filename)
    python scrape_maps.py --max-pages 3          # limit pages per region
"""

import argparse
import json
import re
import sys
import time
from dataclasses import dataclass, field, asdict
from pathlib import Path
from typing import Optional

try:
    import requests
    from bs4 import BeautifulSoup
except ImportError:
    print("Missing dependencies. Run: pip install requests beautifulsoup4", file=sys.stderr)
    sys.exit(1)


BASE_URL    = "https://www.farming-simulator.com/mods.php"
DETAIL_URL  = "https://www.farming-simulator.com/mod.php"
REGIONS = {
    "Europe":       "mapEurope",
    "NorthAmerica": "mapNorthAmerica",
    "SouthAmerica": "mapSouthAmerica",
    "Others":       "mapOthers",
}
MIN_RATING     = 4.3
REQUEST_DELAY  = 1.0   # seconds between requests

HEADERS = {
    "User-Agent": (
        "Mozilla/5.0 (Windows NT 10.0; Win64; x64) "
        "AppleWebKit/537.36 (KHTML, like Gecko) "
        "Chrome/124.0.0.0 Safari/537.36"
    ),
    "Accept-Language": "en-US,en;q=0.9",
}


@dataclass
class MapMod:
    region:       str
    name:         str        # display name from listing
    zip_name:     str        # e.g. FS25_Mindenerwald.zip
    rating:       float
    rating_count: int
    detail_url:   str
    author:       str
    description:  str
    mod_id:       str = ""


def parse_rating_num(text: str) -> Optional[float]:
    """Parse '4.5★(369)' or '4(709)' → 4.5 / 4.0"""
    m = re.match(r"([\d]+(?:\.[\d]+)?)", text.strip())
    return float(m.group(1)) if m else None


def parse_rating_count(text: str) -> int:
    m = re.search(r"\((\d+)\)", text)
    return int(m.group(1)) if m else 0


def fetch(session: requests.Session, url: str, params: dict) -> BeautifulSoup:
    resp = session.get(url, params=params, headers=HEADERS, timeout=20)
    resp.raise_for_status()
    return BeautifulSoup(resp.text, "html.parser")


def fetch_detail(session: requests.Session, mod_id: str) -> tuple[str, str, str]:
    """Returns (zip_filename, description, category) from a mod detail page."""
    soup = fetch(session, DETAIL_URL, {"mod_id": mod_id, "title": "fs2025"})

    # Description is in div.top-line (inside the large content column)
    desc_el = soup.select_one("div.top-line")
    description = desc_el.get_text(" ", strip=True) if desc_el else ""

    # Filename and category are table rows in div.table-game-info
    zip_name = ""
    category = ""
    info_table = soup.select_one("div.table-game-info")
    if info_table:
        for row in info_table.select("div.table-row"):
            cells = row.select("div.table-cell")
            if len(cells) < 2:
                continue
            key = cells[0].get_text(strip=True).lower()
            val = cells[1].get_text(strip=True)
            if key == "filename":
                zip_name = val
            elif key == "category":
                category = val

    return zip_name, description, category


def scrape_region(
    session:    requests.Session,
    label:      str,
    filt:       str,
    min_rating: float,
    max_pages:  int,
    fetch_details: bool,
) -> list[MapMod]:
    results: list[MapMod] = []

    for page in range(max_pages):
        print(f"  [{label}] page {page}...", file=sys.stderr)
        soup = fetch(session, BASE_URL, {"title": "fs2025", "filter": filt, "page": page})

        cards = soup.select("div.mod-item")
        if not cards:
            print(f"  [{label}] no cards found, stopping", file=sys.stderr)
            break

        print(f"  [{label}] page {page}: {len(cards)} cards total", file=sys.stderr)
        for card in cards:
            # Title — in <h4>, no anchor wrapper
            title_el = card.select_one("div.mod-item__content h4")
            if not title_el:
                continue
            name = title_el.get_text(strip=True)

            # Detail link — anchor is in the image div
            link_el = card.select_one("div.mod-item__img a")
            href = link_el["href"] if link_el else ""
            # href looks like "mod.php?mod_id=360526&title=fs2025"
            mod_id_m = re.search(r"mod_id=(\d+)", href)
            mod_id = mod_id_m.group(1) if mod_id_m else ""
            detail_url = (
                "https://www.farming-simulator.com/" + href.lstrip("/")
                if href and not href.startswith("http")
                else href
            )

            # Rating number — div.mod-item__rating-num, text like "4.5★(369)"
            rating_el = card.select_one("div.mod-item__rating-num")
            if not rating_el:
                continue
            rating_text = rating_el.get_text(strip=True)
            rating_val = parse_rating_num(rating_text)
            if rating_val is None or rating_val < min_rating:
                continue
            rating_count = parse_rating_count(rating_text)

            # Author — <p><span>By: name</span></p>
            author_el = card.select_one("div.mod-item__content p span")
            author = author_el.get_text(strip=True).removeprefix("By:").strip() if author_el else ""

            # Description + exact filename + category from detail page
            zip_name, description, category = "", "", ""
            if fetch_details and mod_id:
                time.sleep(REQUEST_DELAY)
                try:
                    zip_name, description, category = fetch_detail(session, mod_id)
                except Exception as e:
                    print(f"    detail fetch failed for {name}: {e}", file=sys.stderr)

            # Skip mods miscategorised on the listing page (e.g. prefabs, vehicles)
            if category and "map" not in category.lower():
                print(f"    - skipping {name} (category: {category})", file=sys.stderr)
                continue

            if not zip_name:
                zip_name = name  # fallback: use display name

            results.append(MapMod(
                region=label,
                name=name,
                zip_name=zip_name,
                rating=rating_val,
                rating_count=rating_count,
                detail_url=detail_url,
                author=author,
                description=description,
                mod_id=mod_id,
            ))
            print(f"    + {zip_name}  {rating_val}★ ({rating_count})", file=sys.stderr)

        # Pagination: div.pagination-next contains an <a> when there's a next page
        next_div = soup.select_one("div.pagination-next")
        if not next_div or not next_div.select_one("a"):
            print(f"  [{label}] no next page, done", file=sys.stderr)
            break

        time.sleep(REQUEST_DELAY)  # pause before next listing page

    return results


def format_text(mods: list[MapMod]) -> str:
    out = []
    current_region = None
    for m in sorted(mods, key=lambda x: (x.region, -x.rating)):
        if m.region != current_region:
            current_region = m.region
            out.append(f"\n{'='*60}")
            out.append(f"  {current_region}")
            out.append(f"{'='*60}")

        out.append(f"\n{m.zip_name}  [{m.rating:.2f}*, {m.rating_count} votes]")
        out.append(f"Author : {m.author}")
        out.append(f"URL    : {m.detail_url}")
        if m.description:
            out.append("Desc   :")
            # Wrap at 78 chars
            words, line, lines = m.description.split(), [], []
            for w in words:
                if sum(len(x) + 1 for x in line) + len(w) > 78:
                    lines.append("  " + " ".join(line))
                    line = [w]
                else:
                    line.append(w)
            if line:
                lines.append("  " + " ".join(line))
            out.extend(lines)

    return "\n".join(out)


def main():
    parser = argparse.ArgumentParser(description="Scrape FS25 map mods rated 4.5+ stars")
    parser.add_argument("--region", choices=list(REGIONS.values()), default=None,
                        help="Scrape one region only (default: all)")
    parser.add_argument("--min-rating", type=float, default=MIN_RATING,
                        help=f"Minimum star rating (default: {MIN_RATING})")
    parser.add_argument("--max-pages", type=int, default=50,
                        help="Max pages per region (default: 50)")
    parser.add_argument("--output", type=str, default=None,
                        help="Write results to a JSON file instead of stdout")
    parser.add_argument("--no-detail", action="store_true",
                        help="Skip detail page fetches (faster, no description/filename)")
    args = parser.parse_args()

    regions_to_scrape = (
        {lbl: flt for lbl, flt in REGIONS.items() if flt == args.region}
        if args.region else REGIONS
    )

    session   = requests.Session()
    all_mods: list[MapMod] = []

    for label, filt in regions_to_scrape.items():
        print(f"\nScraping {label}...", file=sys.stderr)
        mods = scrape_region(session, label, filt, args.min_rating,
                             args.max_pages, not args.no_detail)
        print(f"  [{label}] {len(mods)} mods >= {args.min_rating}*", file=sys.stderr)
        all_mods.extend(mods)

    # --- manual additions / overrides ---

    zip_names = {m.zip_name for m in all_mods}

    # 1. Alias FS25_Saxlingham.zip from crossplay variant if present
    saxlingham_src = next(
        (m for m in all_mods if m.zip_name == "FS25_Saxlingham_crossplay.zip"), None
    )
    if saxlingham_src and "FS25_Saxlingham.zip" not in zip_names:
        import copy
        alias = copy.copy(saxlingham_src)
        alias.zip_name = "FS25_Saxlingham.zip"
        all_mods.append(alias)
        print("  + added FS25_Saxlingham.zip (alias of crossplay)", file=sys.stderr)

    # 2. Inject FS25_Witcombe.zip if not already present
    if "FS25_Witcombe.zip" not in zip_names:
        all_mods.append(MapMod(
            region="Europe",
            name="Witcombe",
            zip_name="FS25_Witcombe.zip",
            rating=5.0,
            rating_count=10000,
            detail_url="",
            author="",
            description="Inspired by the countryside of Gloucestershire, UK",
        ))
        print("  + added FS25_Witcombe.zip (manual)", file=sys.stderr)

    print(f"\nTotal: {len(all_mods)} mods", file=sys.stderr)

    if args.output:
        path = Path(args.output)
        slim = [
            {
                "zip_name":     m.zip_name,
                "description":  m.description,
                "rating":       m.rating,
                "rating_count": m.rating_count,
            }
            for m in all_mods
        ]
        path.write_text(json.dumps(slim, indent=2, ensure_ascii=False), encoding="utf-8")
        print(f"Wrote {path}", file=sys.stderr)
    else:
        sys.stdout.reconfigure(encoding="utf-8")
        print(format_text(all_mods))


if __name__ == "__main__":
    main()
