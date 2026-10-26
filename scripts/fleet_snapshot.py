#!/usr/bin/env python3
"""Snapshot the Adelaide Metro bus fleet into AdelaideTransit/Resources/fleet.json.

The realtime feed publishes only a fleet number per vehicle (`vehicle.label`), so rego, chassis, body and
build date come from the enthusiast-maintained Australian Bus Fleet Lists (fleetlists.busaustralia.com).
Its robots.txt says `use=reference`: this is a personal app, and the snapshot must not ship in a
distributed build without the site owner's permission.

Photos come from Wikimedia Commons (freely licensed; the app shows the credit). Enthusiasts name files
"<operator> <fleet number> …", so a bus gets a photo of *itself* when one exists, else one of its model.

Re-run by hand when the fleet changes:  python3 scripts/fleet_snapshot.py
"""

import html
import json
import re
import sys
import urllib.parse
import urllib.request
from pathlib import Path

BASE = "https://fleetlists.busaustralia.com/adm.php?search="
# The three Adelaide Metro bus contractors, as linked from index-sa.php.
OPERATORS = {
    "TTC": "Torrens Connect",
    "SOU20": "SouthLink",
    "BSA": "Busways",
}
ROOT = Path(__file__).resolve().parent.parent
OUT = ROOT / "AdelaideTransit" / "Resources" / "fleet.json"
COMMONS = "https://commons.wikimedia.org/w/api.php?format=json&"
COMMONS_ROOTS = ["Category:Buses in Adelaide", "Category:O-Bahn Busway"]
# Operator names as Commons photographers write them, including pre-rebrand ones.
OPERATOR_ALIASES = {
    "Torrens Connect": r"Torrens (?:Transit|Connect)",
    "SouthLink": r"South ?Link",
    "Busways": r"Busways",
}
UA = {"User-Agent": "AdelaideTransit fleet snapshot (personal use)"}


def get(url: str) -> str:
    with urllib.request.urlopen(urllib.request.Request(url, headers=UA), timeout=30) as resp:
        return resp.read().decode("utf-8", "replace")


def fetch(code: str) -> str:
    return get(BASE + code)


def commons(params: str) -> dict:
    return json.loads(get(COMMONS + params))


def commons_files() -> list[str]:
    """Every file under the Adelaide bus categories; subcategories only while they stay Adelaide-bus shaped."""
    seen, files, queue = set(), [], list(COMMONS_ROOTS)
    while queue:
        cat = queue.pop(0)
        if cat in seen:
            continue
        seen.add(cat)
        cont = ""
        while True:
            r = commons(f"action=query&list=categorymembers&cmlimit=500&cmtitle={urllib.parse.quote(cat)}{cont}")
            for m in r["query"]["categorymembers"]:
                title = m["title"]
                if title.startswith("Category:"):
                    if re.search(r"torrens|southlink|busways|o-bahn|adelaide metro|buses in adelaide", title, re.I):
                        queue.append(title)
                elif re.search(r"\.(jpe?g|png)$", title, re.I):
                    files.append(title)
            if "continue" not in r:
                break
            cont = "&cmcontinue=" + urllib.parse.quote(r["continue"]["cmcontinue"])
    return sorted(set(files))


def fleet_number_in(title: str, operator: str, fleet: dict) -> str | None:
    if not re.search(OPERATOR_ALIASES[operator], title, re.I):
        return None
    # Dates in filenames ("2025-12-12", "20250208-105018", "November 2024") would otherwise read as fleet numbers.
    t = re.sub(r"\d{4}-\d{2}-\d{2}|\d{8}(?:-\d{6})?|(?:January|February|March|April|May|June|July|August|September|October|November|December) \d{4}", " ", title)
    for n in re.findall(r"(?<![\w-])(\d{3,4})(?![\w-])", t):
        if fleet.get(n, {}).get("operator") == operator:
            return n
    return None


def image_info(titles: list[str]) -> dict[str, dict]:
    out = {}
    for i in range(0, len(titles), 50):
        batch = "|".join(titles[i:i + 50])
        r = commons("action=query&prop=imageinfo&iiprop=url|extmetadata&iiurlwidth=1024&titles="
                    + urllib.parse.quote(batch))
        for page in r["query"]["pages"].values():
            info = (page.get("imageinfo") or [None])[0]
            if not info:
                continue
            meta = info.get("extmetadata", {})
            artist = text(meta.get("Artist", {}).get("value", "")) or "Unknown"
            licence = meta.get("LicenseShortName", {}).get("value", "")
            if not licence or "fair use" in licence.lower():
                continue  # only freely licensed images
            out[page["title"]] = {"url": info["thumburl"], "page": info["descriptionurl"],
                                  "artist": artist, "licence": licence}
    return out


def text(cell: str) -> str:
    cell = re.sub(r"<br\s*/?>", " ", cell)
    cell = re.sub(r"<[^>]+>", " ", cell)
    return re.sub(r"\s+", " ", html.unescape(cell)).strip()


def model_key(chassis: str, body: str) -> str:
    # "Custom Coaches 'CB60 Combo'" -> body model "CB60 Combo"; the key photos are curated against.
    m = re.search(r"'([^']+)'", body)
    return f"{chassis} / {m.group(1) if m else body}"


def parse(page: str, operator: str) -> list[dict]:
    buses = []
    for row in re.findall(r"<tr[^>]*>(.*?)</tr>", page, re.S):
        cells = [text(c) for c in re.findall(r"<td[^>]*>(.*?)</td>", row, re.S)]
        if len(cells) == 1 and buses and buses[-1].get("_open"):
            # The colspan row under a bus: its history ("ex …", "Owned by …").
            if cells[0]:
                buses[-1]["notes"] = cells[0]
            buses[-1].pop("_open")
            continue
        if len(cells) < 10 or not cells[0].isdigit():
            continue
        fleet, rego, chassis, vin, body, body_no, body_date, seating, livery, depot = cells[:10]
        if buses and buses[-1].get("_open"):
            buses[-1].pop("_open")
        buses.append({
            "fleet": fleet,
            "rego": None if rego in ("", "?") else rego,
            "chassis": chassis,
            "vin": vin or None,
            "body": body,
            "bodyNumber": body_no or None,
            "built": body_date or None,
            "seating": seating or None,
            "livery": livery or None,
            "depot": depot or None,
            "operator": operator,
            "model": model_key(chassis, body),
            "_open": True,
        })
    for bus in buses:
        bus.pop("_open", None)
    return buses


def main() -> int:
    fleet: dict[str, dict] = {}
    for code, name in OPERATORS.items():
        buses = parse(fetch(code), name)
        print(f"{name}: {len(buses)}")
        for bus in buses:
            fleet[bus.pop("fleet")] = bus
    # Floor: a changed page layout parses to nothing, and an empty snapshot would silently blank every bus.
    if len(fleet) < 800:
        print(f"only {len(fleet)} buses parsed — page layout changed? not writing", file=sys.stderr)
        return 1
    exact: dict[str, str] = {}
    for title in commons_files():
        for operator in OPERATORS.values():
            n = fleet_number_in(title, operator, fleet)
            if n and n not in exact:
                exact[n] = title
    images = image_info(sorted(set(exact.values())))
    exact = {n: t for n, t in exact.items() if t in images}
    model_photos: dict[str, str] = {}
    for n, title in sorted(exact.items()):
        fleet[n]["photo"] = title
        model_photos.setdefault(fleet[n]["model"], title)
    models = {b["model"] for b in fleet.values()}
    OUT.write_text(json.dumps({"buses": fleet, "modelPhotos": model_photos, "images": images},
                              ensure_ascii=False, sort_keys=True, separators=(",", ":")))
    with_photo = sum(1 for b in fleet.values() if b["model"] in model_photos)
    print(f"wrote {len(fleet)} buses -> {OUT}")
    print(f"photos: {len(exact)} of the bus itself, {len(model_photos)}/{len(models)} models, "
          f"{with_photo}/{len(fleet)} buses with some photo")
    return 0


if __name__ == "__main__":
    sys.exit(main())
