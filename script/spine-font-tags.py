#!/usr/bin/env python3
"""Writes Bookworms/SpineFontTags.json: Google Fonts' category and stroke for each family in
Bookworms/SpineFontAtlas.lzfse, with the family's classification, theme, and mood tags from the
google/fonts repository (`tags/all/families.csv`, human-assessed scores from 0 to 100).

The tag data's license is unconfirmed (https://github.com/google/fonts/issues/9347). Credit
Google Fonts wherever the app shows its sources.

Usage: script/spine-font-tags.py [tags.csv]   (default: downloads the current tags file)
"""
import csv, io, json, os, struct, subprocess, sys, tempfile, urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
TAGS_URL = 'https://raw.githubusercontent.com/google/fonts/main/tags/all/families.csv'
KEPT = ('/Serif/', '/Sans/', '/Slab/', '/Script/', '/Monospace/', '/Theme/', '/Expressive/')

def atlas_families(path):
    """The family names in the atlas (BWA3): skips each font's glyphs by their sizes."""
    with tempfile.NamedTemporaryFile() as raw:
        subprocess.run(['compression_tool', '-decode', '-a', 'lzfse', '-i', path, '-o', raw.name], check=True)
        data = open(raw.name, 'rb').read()
    assert data[:4] == b'BWA3'
    height, count = struct.unpack_from('<HH', data, 4)
    offset = 8 + count
    characters = len(data[8:8 + count].decode('utf-8'))
    families = []
    while offset < len(data):
        length = data[offset]; offset += 1
        families.append(data[offset:offset + length].decode('utf-8')); offset += length + 2
        for _ in range(characters):
            _, _, width = struct.unpack_from('<hHH', data, offset); offset += 6
            offset += (width * height + 1) // 2
    return sorted(set(families))

def main():
    names = atlas_families(os.path.join(ROOT, 'Bookworms', 'SpineFontAtlas.lzfse'))
    text = open(sys.argv[1]).read() if len(sys.argv) > 1 else urllib.request.urlopen(TAGS_URL).read().decode('utf-8')
    tags = {}
    for family, axis, tag, score in csv.reader(io.StringIO(text)):
        if family in names and tag.startswith(KEPT):
            # Rows for an axis position, such as wght@700, fold into the family by maximum.
            key = tag.lstrip('/')
            tags.setdefault(family, {})[key] = max(tags.get(family, {}).get(key, 0), round(float(score)))
    raw = urllib.request.urlopen('https://fonts.google.com/metadata/fonts').read().decode('utf-8')
    meta = {f['family']: f for f in json.loads(raw[raw.index('{'):])['familyMetadataList']}
    out = {name: {'category': meta.get(name, {}).get('category', ''), 'stroke': meta.get(name, {}).get('stroke') or None,
                  'tags': {k: v for k, v in sorted(tags.get(name, {}).items()) if v > 0}} for name in names}
    with open(os.path.join(ROOT, 'Bookworms', 'SpineFontTags.json'), 'w') as f:
        json.dump({'source': TAGS_URL, 'families': out}, f, separators=(',', ':'), sort_keys=True)
    print(len(out), 'families,', sum(1 for v in out.values() if v['tags']), 'with tags')

main()
