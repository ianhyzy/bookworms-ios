#!/usr/bin/env python3
"""Loads a private Bookworms library into the Simulator app as a local preview folder.

Reads an Apple TV library export and its retained spine styles from the workspace `.local`
folder, converts them to the iCloud JSON shapes (`library-v1.json`, `spine-designs-v1.json`),
and copies them, with any cached Google Fonts, into the installed app's Caches folder. Launch
the app with `-BookwormsPreviewFolder preview` to read them instead of iCloud.

The output contains real reading history. It stays in ignored `.local/` folders and the
Simulator; never commit it or publish screenshots made from it.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
BUNDLE_ID = "gay.ian.Bookworms.iOS"
STEPS = {"Thin": 100, "ExtraLight": 200, "Light": 300, "Regular": 400, "Medium": 500,
         "SemiBold": 600, "Bold": 700, "ExtraBold": 800, "Black": 900}


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def work_item_hash(account, book):
    return sha("\n".join([account, str(book["id"]), book["title"], book["author"],
                          book.get("detailCoverURL") or "", book.get("coverURL") or ""]))


def hex_of(color):
    return "#" + "".join(f"{round(color[k] * 255):02X}" for k in ("red", "green", "blue"))


def mix(a, b, amount):
    return {k: a[k] * (1 - amount) + b[k] * amount for k in ("red", "green", "blue")}


def typeface(entry):
    # Matches the Mac and iOS SpineFontStyle.fallbackTypeface groups closely enough for previews.
    if entry["family"] == "Pirata One" or entry["category"] in ("Serif", "Handwriting"):
        return "serif"
    if entry["category"] == "Monospace":
        return "monospaced"
    return "serif" if entry.get("stroke") in ("Serif", "Slab Serif") else "sans"


def build(source, out, account):
    library = json.loads((source / "device-library-refined.json").read_text())
    styles = json.loads((source / "ai-styles.json").read_text())
    catalog_path = source / "device-fonts/catalog.json"
    catalog = {e["family"]: e for e in json.loads(catalog_path.read_text())["familyMetadataList"]}
    books = [dict(b, sources=["hardcover"]) for b in library["books"]]
    by_id = {b["id"]: b for b in books}
    archive = {"version": 1, "designs": {}, "sources": [
        {"source": "hardcover", "accountID": account, "books": books,
         "syncedAt": library["syncedAt"]}]}
    designs = {}
    for record in styles.values():
        style, font = record["style"], record["font"]
        name = font["postScriptName"]
        designs["spine-design-v1-" + sha(f"{account}:{record['bookID']}")] = {
            "version": 1, "accountID": account, "bookID": record["bookID"],
            "workItemHash": work_item_hash(account, by_id[record["bookID"]]),
            "coverHash": record["coverHash"],
            # Not this app's generator, so a Simulator run regenerates these with PCC.
            "generatorVersion": "fixture-ai-styles-v1", "generatedAt": record["generatedAt"],
            "backgroundHex": hex_of(style["background"]),
            "foregroundHex": hex_of(style["foreground"]),
            "accentHex": hex_of(mix(style["foreground"], style["background"], 0.4)),
            "typeface": typeface(catalog[font["family"]]), "weight": record["weight"],
            "uppercase": style["uppercase"], "fontFamily": font["family"],
            "fontPostScriptName": name,
            "instanceWeight": STEPS.get(name.rsplit("-", 1)[-1], record["weight"]),
            "provenance": style["provenance"][:80]}
    out.mkdir(parents=True, exist_ok=True)
    (out / "library-v1.json").write_text(json.dumps(archive, sort_keys=True))
    (out / "spine-designs-v1.json").write_text(json.dumps(designs, sort_keys=True))
    print(f"Wrote {len(books)} books and {len(designs)} designs to {out}")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--source", type=Path, default=ROOT.parent / ".local",
                        help="folder with device-library-refined.json, ai-styles.json, device-fonts")
    parser.add_argument("--simulator", default="booted", help="Simulator UDID or 'booted'")
    parser.add_argument("--account", default="preview", help="account ID to give the snapshot")
    args = parser.parse_args()

    out = ROOT / ".local/preview"
    build(args.source, out, args.account)
    container = subprocess.run(
        ["xcrun", "simctl", "get_app_container", args.simulator, BUNDLE_ID, "data"],
        capture_output=True, text=True)
    if container.returncode != 0:
        sys.exit(f"Install the app on the Simulator first: {container.stderr.strip()}")
    caches = Path(container.stdout.strip()) / "Library/Caches/Bookworms"
    shutil.copytree(out, caches / "preview", dirs_exist_ok=True)
    fonts = args.source / "device-fonts"
    if fonts.is_dir():
        shutil.copytree(fonts, caches / "fonts", dirs_exist_ok=True)
        # GoogleFonts trusts a catalog younger than seven days by its modification date.
        os.utime(caches / "fonts/catalog.json")
    print(f"Copied the preview into {caches}")
    print(f"Launch: xcrun simctl launch {args.simulator} {BUNDLE_ID} "
          "-BookwormsPreviewFolder preview")


if __name__ == "__main__":
    main()
