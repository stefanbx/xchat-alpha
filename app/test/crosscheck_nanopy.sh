#!/usr/bin/env bash
# CROSS-LANGUAGE CHECK for the web signer.
#
# Byte-equality with nanodart (ed25519_blake2b_test.dart) proves the two Dart implementations agree.
# This proves the thing that actually decides whether a post or a tip is accepted: that the NODE —
# a different language, a different library (nanopy, ed25519-blake2b in C) — verifies what the browser
# signs. If this passes, a signature made in a browser is indistinguishable from one made on a phone.
#
#   bash test/crosscheck_nanopy.sh
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="$HOME/flutter/bin:$PATH"

VEC=$(mktemp -t xcvec).json
trap 'rm -f "$VEC" test/_emit_vectors_test.dart' EXIT

cat > test/_emit_vectors_test.dart <<'DART'
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:xchat/crypto/ed25519_blake2b.dart' as web;

void main() {
  test('emit vectors', () {
    final rng = Random(20260815);
    String hex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
    Uint8List rnd(int n) => Uint8List.fromList(List.generate(n, (_) => rng.nextInt(256)));
    final out = [];
    for (int i = 0; i < 60; i++) {
      final sk = rnd(32);
      // Mix raw byte messages with the exact canonical strings the app signs, so the check covers
      // the real preimages (sig_canon) and not just random blobs.
      final msg = i % 3 == 0
          ? Uint8List.fromList(utf8.encode('xchat/sig/v2/post|4:test|${i}'))
          : rnd([0, 1, 31, 32, 33, 64, 65, 200][i % 8]);
      out.add({
        'pub': hex(web.publicKeyFromSecret(sk)),
        'msg': hex(msg),
        'sig': hex(web.signDetached(msg, sk)),
      });
    }
    File(Platform.environment['XC_VEC_OUT']!).writeAsStringSync(jsonEncode(out));
  });
}
DART

echo "→ generating signatures in Dart (BigInt implementation)…"
XC_VEC_OUT="$VEC" flutter test test/_emit_vectors_test.dart >/dev/null

echo "→ verifying them with the node's Python verifier (nanopy)…"
python3 - "$VEC" <<'PY'
import json, sys, importlib.util, os
here = os.path.dirname(os.path.abspath(sys.argv[0])) if False else os.getcwd()
spec = importlib.util.spec_from_file_location('xc', os.path.join(here, '..', 'backend', 'xc_common.py'))
xc = importlib.util.module_from_spec(spec); spec.loader.exec_module(xc)

vectors = json.load(open(sys.argv[1]))
bad = 0
for i, v in enumerate(vectors):
    msg = bytes.fromhex(v['msg'])
    if not xc.verify_msg(v['pub'], msg, v['sig']):
        bad += 1
        print(f"  FAIL vector {i}: pub={v['pub'][:16]}… msg={v['msg'][:32]}…")
    # and the node must REJECT it once tampered with
    t = bytearray(bytes.fromhex(v['sig'])); t[0] ^= 1
    if xc.verify_msg(v['pub'], msg, t.hex()):
        bad += 1
        print(f"  FAIL vector {i}: node accepted a TAMPERED signature")
    # ...and reject it against a different message
    if msg and xc.verify_msg(v['pub'], msg + b'x', v['sig']):
        bad += 1
        print(f"  FAIL vector {i}: node accepted a signature over a different message")

print(f"\n{len(vectors)} vectors × (verify + tamper + wrong-message)")
print("ALL PASS — the node accepts browser-made signatures" if bad == 0 else f"{bad} FAILURES")
sys.exit(1 if bad else 0)
PY
