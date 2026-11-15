#!/usr/bin/env python3
"""Exports the owner's recent reading as the app's bundled example profile.

Reads the signed-in Mac app's launch cache (`library-snapshot.json`) and writes the folder shape
that `LocalSpineStore` reads: `library-v1.json`, `spine-designs-v1.json`,
`series-looks-v1.json`, `cover-choices-v1.json`, and `series-links-v1.json`. It keeps only books
on the Read shelf finished on or after `SINCE`, and only their finish dates since then, with the
series, designs, looks, chosen covers, and series links those books use. Every record moves to the
account ID `example`, which no Hardcover account matches, with its record name and work-item hash
recomputed.

It strips reviews and Hardcover's community ratings, and calls no API: it reads no token, no
Keychain item, and no file besides the cache. The output is the owner's private reading history.
Keep it out of Git (`.gitignore` lists `ExampleProfile/`) and print only counts.

Run it with `python3 -I script/export-example-profile.py --out ExampleProfile` before archiving
(see `docs/RELEASING.md`).
"""
import argparse
import hashlib
import json
import unicodedata
from pathlib import Path

SOURCE = (Path.home() / "Library/Containers/gay.ian.Bookworms.Mac/Data/Library/Caches"
          / "Bookworms/library-snapshot.json")
ACCOUNT = "example"
SINCE = "2024-01-01"
READ_STATUS = 3
# Reviews are the owner's to share, and Hardcover allows its aggregates only when labeled as
# Hardcover data, which the details card doesn't do.
STRIPPED = ("review", "communityRating", "ratingsCount", "ratingDistribution")
# The reader's choices, which the archive never carries: they become `CoverChoiceV1` and
# `SeriesLinkV1` records, as the apps read them.
CHOICES = ("chosenCoverURL", "seriesLink")


def sha(text):
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def work_item_hash(account, book):
    # `CloudContract.workItemHash(accountID:book:)`.
    return sha("\n".join([account, str(book["id"]), book["title"], book["author"],
                          book.get("detailCoverURL") or "", book.get("coverURL") or ""]))


def fold(text):
    text = unicodedata.normalize("NFKD", text).casefold()
    return "".join(c for c in text if c.isalnum() and not unicodedata.combining(c))


def style_series(book, link):
    # `SeriesDesigns.styleSeries(of:link:)`: the linked series, else the shortest series.
    if link:
        if link["standsAlone"]:
            return None
        if link.get("linkedSeriesID"):
            return link["linkedSeriesID"]
    memberships = book.get("seriesMemberships")
    if memberships is None:
        return book.get("seriesID")
    if not memberships:
        return None

    def order(m):
        size = m.get("size")
        return (1 if m["compilation"] else 0, size if size and size >= 2 else float("inf"),
                0 if m["featured"] else 1, m["seriesID"])
    return min(memberships, key=order)["seriesID"]


def first_author(book):
    keys = [fold(name) for name in book["author"].split(", ")]
    return next((k for k in keys if k), "")


def export(snapshot, out):
    real_account = snapshot["accountID"]
    read = [b for b in snapshot["books"]
            if b.get("statusID") == READ_STATUS and (b.get("finished") or "") >= SINCE]
    covers = {b["id"]: b["chosenCoverURL"] for b in read if b.get("chosenCoverURL")}
    links = {b["id"]: b["seriesLink"] for b in read if b.get("seriesLink")}
    kept = [dict((k, v) for k, v in b.items() if k not in STRIPPED + CHOICES) for b in read]
    # A re-read keeps only its finishes since `SINCE`; `finished`, the newest, is one of them.
    trimmed = 0
    for book in kept:
        dates = book.get("finishedDates")
        if dates:
            recent = [d for d in dates if d >= SINCE]
            trimmed += len(dates) - len(recent)
            book["finishedDates"] = recent
    by_id = {b["id"]: b for b in kept}

    used_series = {m["seriesID"] for b in kept for m in b.get("seriesMemberships") or []}
    used_series |= {b["seriesID"] for b in kept if b.get("seriesID")}
    series = [s for s in snapshot.get("series") or [] if s["id"] in used_series]

    # A copied design's provenance names its source ("series-reuse:<bookID>"). A source that
    # wasn't exported becomes the design's own book, since a Hardcover book ID reveals the earlier
    # reading. The apps check only the token's prefix.
    kept_ids = {str(i) for i in by_id}
    designs, stale = {}, 0
    for design in snapshot["designs"].values():
        book = by_id.get(design["bookID"])
        if book is None or design["accountID"] != real_account:
            continue
        stale += design["workItemHash"] != work_item_hash(real_account, book)
        design = dict(design, accountID=ACCOUNT, workItemHash=work_item_hash(ACCOUNT, book))
        if design.get("provenance"):
            design["provenance"] = " ".join(
                f"series-reuse:{book['id']}"
                if t.startswith("series-reuse:") and t[len("series-reuse:"):] not in kept_ids
                else t for t in design["provenance"].split(" "))
        designs["spine-design-v1-" + sha(f"{ACCOUNT}:{book['id']}")] = design

    # A look's group is "<subseries>|<first author>" (`SeriesDesigns.lookKey(of:link:)`).
    # ponytail: matches the style series and first author but not the Discworld subseries
    # table, so it can keep a Discworld look no kept book draws; port the table if that matters.
    # A look whose source book wasn't exported names a kept member instead, since a Hardcover
    # book ID reveals the earlier reading. The app checks only that the ID is positive.
    # A book whose link keeps its own look draws none.
    members = {}
    for book in sorted(kept, key=lambda b: b["id"]):
        link = links.get(book["id"])
        if not (link and link["ownLook"]):
            members.setdefault((style_series(book, link), first_author(book)), book["id"])
    raw_looks = snapshot["looks"]
    looks = {}
    for key, look in zip(raw_looks[::2], raw_looks[1::2]):
        if look["accountID"] != real_account:
            continue
        member = members.get((key["seriesID"], key["group"].split("|", 1)[-1]))
        if member is None:
            continue
        source = look["sourceBookID"] if look["sourceBookID"] in by_id else member
        look = dict(look, accountID=ACCOUNT, sourceBookID=source)
        looks["series-look-v1-" + sha(f"{ACCOUNT}:{key['seriesID']}:{key['group']}")] = look

    # The launch cache keeps only a chosen cover's URL, so the record dates it to the sync and
    # names no edition, which only the cover picker reads.
    cover_choices = {
        "cover-choice-v1-" + sha(f"{ACCOUNT}:{i}"): {
            "version": 1, "accountID": ACCOUNT, "bookID": i, "coverURL": url,
            "chosenAt": snapshot["syncedAt"]}
        for i, url in covers.items()}
    series_links = {"series-link-v1-" + sha(f"{ACCOUNT}:{i}"): dict(link, accountID=ACCOUNT)
                    for i, link in links.items()}

    archive = {"version": 1, "sources": [{
        "source": "hardcover", "accountID": ACCOUNT, "books": kept,
        "syncedAt": snapshot["syncedAt"], "series": series}]}
    out.mkdir(parents=True, exist_ok=True)
    for name, value in (("library-v1.json", archive), ("spine-designs-v1.json", designs),
                        ("series-looks-v1.json", looks), ("cover-choices-v1.json", cover_choices),
                        ("series-links-v1.json", series_links)):
        (out / name).write_text(json.dumps(value, sort_keys=True, separators=(",", ":")))
    # Counts only: the folder holds private reading history.
    print(f"Kept {len(kept)} of {len(snapshot['books'])} books, {len(series)} series, "
          f"{len(designs)} designs ({stale} with an outdated work-item hash), "
          f"{len(looks)} looks, {len(cover_choices)} chosen covers, and {len(series_links)} "
          f"series links; dropped {trimmed} earlier finish dates.")


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--out", type=Path, required=True,
                        help="folder to write, such as ExampleProfile in the repository root")
    args = parser.parse_args()
    export(json.loads(SOURCE.read_text()), args.out)


if __name__ == "__main__":
    main()
