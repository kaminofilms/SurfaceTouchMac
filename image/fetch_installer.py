#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Find (and optionally download) the newest full macOS installer for a major
version from Apple's own software-update catalog. Downloads come only from
Apple (swcdn.apple.com); the caller must still verify the package signature
with `pkgutil --check-signature` (Apple Software Update certificate).

  fetch_installer.py --major 26 [--download DIR]
"""
import argparse
import gzip
import json
import plistlib
import re
import sys
import urllib.request

CATALOG = ("https://swscan.apple.com/content/catalogs/others/"
           "index-26-15-14-13-12-10.16-10.15-10.14-10.13-10.12-10.11-10.10-10.9-"
           "mountainlion-lion-snowleopard-leopard.merged-1.sucatalog.gz")
APPLE_HOSTS = ("swcdn.apple.com", "swdist.apple.com", "swscan.apple.com", "updates.cdn-apple.com")


def fetch(url):
    host = re.sub(r"^https?://([^/]+)/.*$", r"\1", url)
    if not host.endswith(APPLE_HOSTS):
        raise SystemExit(f"refusing non-Apple URL {url}")
    with urllib.request.urlopen(url, timeout=120) as r:
        data = r.read()
    return gzip.decompress(data) if url.endswith(".gz") else data


def version_key(v):
    return [int(x) for x in re.findall(r"\d+", v)]


def find(major):
    cat = plistlib.loads(fetch(CATALOG))
    found = []
    for pid, prod in cat.get("Products", {}).items():
        meta = prod.get("ExtendedMetaInfo", {}).get("InstallAssistantPackageIdentifiers")
        if not meta:
            continue
        pkgs = prod.get("Packages", [])
        ia = [p for p in pkgs if p.get("URL", "").endswith("InstallAssistant.pkg")]
        if not ia:
            continue
        dist_url = (prod.get("Distributions") or {}).get("English") or next(iter((prod.get("Distributions") or {}).values()), None)
        if not dist_url:
            continue
        dist = fetch(dist_url).decode("utf-8", "replace")
        vm = re.search(r"<key>VERSION</key>\s*<string>([^<]+)</string>", dist)
        bm = re.search(r"<key>BUILD</key>\s*<string>([^<]+)</string>", dist)
        if not vm:
            continue
        version = vm.group(1)
        if version_key(version)[0] != major:
            continue
        beta = "beta" in dist.lower() and "seed" in dist.lower()
        found.append({
            "product": pid, "version": version, "build": bm.group(1) if bm else "",
            "url": ia[0]["URL"], "size": ia[0].get("Size", 0),
            "integrity": ia[0].get("IntegrityDataURL", ""), "beta": beta,
            "posted": str(prod.get("PostDate", "")),
        })
    found = [f for f in found if not f["beta"]]
    found.sort(key=lambda f: (version_key(f["version"]), f["posted"]))
    return found


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--major", type=int, required=True)
    ap.add_argument("--download")
    a = ap.parse_args()
    found = find(a.major)
    if not found:
        raise SystemExit(f"no macOS {a.major} full installer in Apple's catalog")
    for f in found:
        print(f"available: macOS {f['version']} ({f['build']}) product {f['product']} {f['size'] / 1e9:.1f} GB", file=sys.stderr)
    best = found[-1]
    print(json.dumps(best))
    if a.download:
        import os, shutil
        dest = os.path.join(a.download, "InstallAssistant.pkg")
        print(f"downloading {best['url']}", file=sys.stderr)
        with urllib.request.urlopen(best["url"], timeout=600) as r, open(dest, "wb") as f:
            shutil.copyfileobj(r, f, 1 << 24)
        if best["size"] and os.path.getsize(dest) != best["size"]:
            raise SystemExit("size mismatch after download")


if __name__ == "__main__":
    main()
