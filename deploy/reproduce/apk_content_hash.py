#!/usr/bin/env python3
"""apk_content_hash.py — the reproducibility trust anchor for ӾChat.

A signed APK is not byte-reproducible by a third party: the APK Signing Block
(v2/v3) and the v1 META-INF/*.SF|*.RSA files depend on the PRIVATE signing key,
which only the publisher holds. So "rebuild and diff the .apk file" can never
work for anyone but us.

What IS reproducible is the *content*: every actual file inside the APK
(the Dart AOT snapshot libapp.so, the native libs, flutter_assets, classes.dex,
resources, AndroidManifest.xml, ...). This tool computes a single hash over that
content that is deliberately blind to everything a re-packager or a different
signer can legitimately change:

  * ZIP entry timestamps          (ignored — we hash content, not the ZIP header)
  * ZIP entry ordering            (ignored — entries are sorted by name)
  * compression method / level    (ignored — we hash the UNCOMPRESSED bytes)
  * the signing key                (ignored — signature files are excluded)

The result: two builds of the same source with the same pinned toolchain produce
the SAME content hash even when the .apk files differ byte-for-byte, and a
verifier who lacks our key can still confirm the app they run is the published
one. The signature is then checked SEPARATELY against the publisher's cert
(apksigner verify) — reproducibility proves "this binary == this source",
the signature proves "this binary == the one the publisher blessed".

Usage:
    apk_content_hash.py app.apk                # prints the content hash
    apk_content_hash.py app.apk --manifest     # + the per-entry manifest
    apk_content_hash.py a.apk b.apk --diff      # what differs between two APKs
    apk_content_hash.py app.apk --json          # machine-readable
"""
import argparse
import hashlib
import json
import sys
import zipfile

# v1 (JAR) signature artifacts — excluded so the content hash is signer-independent.
# (The v2/v3 APK Signing Block is not a ZIP entry, so zipfile never yields it.)
SIG_PREFIXES = ("META-INF/",)
SIG_SUFFIXES = (".SF", ".RSA", ".DSA", ".EC")
SIG_EXACT = ("META-INF/MANIFEST.MF",)


def is_signature_entry(name: str) -> bool:
    if name in SIG_EXACT:
        return True
    if name.startswith(SIG_PREFIXES):
        return name.endswith(SIG_SUFFIXES)
    return False


def entry_hashes(path: str) -> dict[str, str]:
    """name -> sha256(uncompressed bytes), excluding signature files."""
    out: dict[str, str] = {}
    with zipfile.ZipFile(path) as z:
        for info in z.infolist():
            name = info.filename
            if name.endswith("/"):  # directory entry, no content
                continue
            if is_signature_entry(name):
                continue
            with z.open(info) as f:
                out[name] = hashlib.sha256(f.read()).hexdigest()
    return out


def content_hash(entries: dict[str, str]) -> str:
    """A single hash over the sorted (name, sha256) set — order/time/signer blind."""
    h = hashlib.sha256()
    for name in sorted(entries):
        h.update(name.encode("utf-8"))
        h.update(b"\0")
        h.update(entries[name].encode("ascii"))
        h.update(b"\n")
    return h.hexdigest()


def file_sha256(path: str) -> str:
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def main() -> int:
    ap = argparse.ArgumentParser(description="Content-identity hash of an APK.")
    ap.add_argument("apk", nargs="+", help="APK file(s)")
    ap.add_argument("--manifest", action="store_true", help="print per-entry hashes")
    ap.add_argument("--diff", action="store_true", help="compare exactly two APKs")
    ap.add_argument("--json", action="store_true", help="machine-readable output")
    args = ap.parse_args()

    if args.diff:
        if len(args.apk) != 2:
            print("--diff needs exactly two APKs", file=sys.stderr)
            return 2
        a, b = (entry_hashes(p) for p in args.apk)
        names = sorted(set(a) | set(b))
        differing = []
        for n in names:
            if a.get(n) != b.get(n):
                differing.append(n)
        if args.json:
            print(json.dumps({
                "apk_a": args.apk[0], "apk_b": args.apk[1],
                "content_hash_a": content_hash(a), "content_hash_b": content_hash(b),
                "identical": not differing,
                "differing_entries": differing,
            }, indent=2))
        else:
            print(f"A content hash: {content_hash(a)}  ({args.apk[0]})")
            print(f"B content hash: {content_hash(b)}  ({args.apk[1]})")
            if not differing:
                print("\n✅ IDENTICAL content — the two APKs contain byte-identical files.")
            else:
                print(f"\n❌ {len(differing)} entr{'y' if len(differing)==1 else 'ies'} differ:")
                for n in differing:
                    only = " (only in A)" if n not in b else " (only in B)" if n not in a else ""
                    print(f"   {n}{only}")
        return 0 if not differing else 1

    # single / multiple report
    results = []
    for p in args.apk:
        entries = entry_hashes(p)
        results.append({
            "apk": p,
            "file_sha256": file_sha256(p),
            "content_hash": content_hash(entries),
            "entry_count": len(entries),
            "entries": entries if args.manifest else None,
        })

    if args.json:
        for r in results:
            if not args.manifest:
                r.pop("entries")
        print(json.dumps(results if len(results) > 1 else results[0], indent=2))
    else:
        for r in results:
            print(f"apk:          {r['apk']}")
            print(f"file_sha256:  {r['file_sha256']}")
            print(f"content_hash: {r['content_hash']}")
            print(f"entries:      {r['entry_count']} (signature files excluded)")
            if args.manifest:
                print("--- manifest (name  sha256) ---")
                for name in sorted(r["entries"]):
                    print(f"  {r['entries'][name]}  {name}")
            print()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
