# Reproducible builds

ӾChat's self-update flow doesn't ask you to trust a publisher — it asks you to trust
**the open source code**. This directory lets anyone rebuild the Android APK from source
and confirm the app they're running is exactly what's in this repo, with no privileged
access and without our signing key.

## Why not just "diff the .apk file"?

A published APK is signed. The signature (the v2/v3 APK Signing Block, and the v1
`META-INF/*.SF|*.RSA` files) is a function of our **private key**, which nobody else has.
So a byte-for-byte diff of the `.apk` can never match for a third party — not because the
code differs, but because they can't reproduce our signature.

We anchor trust one layer down, on the **content**: the Dart AOT snapshot (`libapp.so`),
the native libraries, `flutter_assets`, `classes.dex`, resources, and the manifest — every
actual file inside the APK. `apk_content_hash.py` hashes that content in a way that is
deliberately blind to everything a re-packager or a different signer can legitimately change:

| Varies between builds/signers | How the content hash handles it |
|---|---|
| ZIP entry timestamps | ignored — hashes file content, not ZIP headers |
| ZIP entry ordering | ignored — entries sorted by name |
| compression method/level | ignored — hashes the **uncompressed** bytes |
| the signing key | ignored — signature files excluded |

Two builds of the same source on the same pinned toolchain yield the **same content hash**
even when the `.apk` files differ byte-for-byte.

## Verify a release

```bash
cd deploy/reproduce
./reproduce.sh <published_content_hash>
```

It checks your toolchain against `toolchain.lock`, does a clean `flutter build apk --release`
(arm64), computes the content hash, and prints **PASS**/**FAIL** against the hash published in
the release record. PASS means: the binary you'd install is built from this exact source.

Then confirm the publisher actually blessed that binary (separate, independent check):

```bash
apksigner verify --print-certs app-arm64-v8a-release.apk   # cert SHA-256 must match README
```

- **Reproducibility** proves *binary == source*.
- **Signature** proves *binary == the one the publisher released*.

They're orthogonal on purpose: reproducibility means a stolen key still can't push code that
isn't in the public repo without every verifier seeing the mismatch.

## Files

- `apk_content_hash.py` — the content-identity hasher (also `--diff a.apk b.apk`, `--manifest`, `--json`).
- `reproduce.sh` — pinned-toolchain clean build + hash + optional PASS/FAIL.
- `toolchain.lock` — the exact toolchain a reproduction must use.
- `buildenv.sh` — machine-local paths (Flutter/JDK/Android SDK); override via env.

## Pinned toolchain

See `toolchain.lock`. A reproduction must match it; `reproduce.sh` refuses a mismatched
toolchain (override with `SKIP_TOOLCHAIN_CHECK=1`, at the cost of a possibly different hash).

## Two ways to reproduce

| | `reproduce.sh` (host) | `reproduce-docker.sh` (container) |
|---|---|---|
| Where it builds | your machine, at your checkout path | pinned image, at the canonical path `/build/xchat` |
| Toolchain | must match `toolchain.lock` yourself | baked into the image |
| Content hash is stable across… | rebuilds **at the same path** | **any host OS** |
| Use it to | quick local check | match the published release hash |

The published release hash comes from the **container** build on **linux/amd64** — produced by
CI on a native amd64 runner (`.github/workflows/reproduce.yml`). Use `reproduce.sh` for a fast
same-machine sanity check; use `reproduce-docker.sh` to actually verify a release.

> **Architecture is part of the contract.** The Android **NDK ships x86-64-only host
> toolchains**, so the native-code build genuinely cannot run on arm64 Linux (it fails at
> `:app:configureCMakeRelease`). The canonical hash is therefore defined on `linux/amd64`.
> On an Apple-Silicon (arm64) host, run it under emulation:
> `REPRO_PLATFORM=linux/amd64 ./reproduce-docker.sh` (needs `docker buildx`; slower, same hash).
> On a native amd64 host — including any CI runner — it's amd64 already.

### Why the container is necessary (measured, not assumed)

Building the same source twice was tested to pin down every non-deterministic input:

- **Same path, clean rebuild → byte-identical content** (all 297 entries match). The build is
  deterministic on a fixed toolchain + path.
- **Different path → exactly two entries differ**: `lib/arm64-v8a/libapp.so` (the Dart AOT
  snapshot embeds one absolute source URI, `…/.dart_tool/…/dart_plugin_registrant.dart`; a
  path of a different length reshuffles the whole snapshot) and `lib/arm64-v8a/libdartjni.so`
  (a 20-byte ELF build-id note derived from the build directory). **Nothing else.**

Both differences are purely a function of *where* the build ran, so building at a fixed
canonical path inside the container removes them and makes the content hash host-independent.

## Scope & honesty

- Reproducibility proves **provenance**, not innocence: it shows the binary matches the
  published source. Whether that source is trustworthy is a separate question answered by
  human review of an open, un-censorable repository.
- The **content hash** (signature-blind, order-blind, timestamp-blind) is the portable trust
  anchor. Full **file-level** `.apk` sha256 equality additionally requires identical ZIP
  packaging and the same signing key, so it is not the verification target; the content hash is.
