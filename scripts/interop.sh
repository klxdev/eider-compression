#!/bin/sh
# Checks the codecs against reference implementations installed on this machine: gzip(1), and
# Python's zlib and (3.14+) compression.zstd. For a corpus of text, noise, zeros and a mixture:
# what the reference compresses, Eider decodes to the same bytes; what Eider compresses at each
# level, the reference decodes to the same bytes. A reference that is missing is a skipped
# check, not a failure.
#
#   sh scripts/interop.sh
#
# Prints `ok   interop <what>` or `FAIL interop <what>`; exits 1 on a failure, 2 when there is
# no usable toolchain.
here=$(cd "$(dirname "$0")/.." && pwd -P)
. "$here/scripts/env.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$here" || exit 1
fail=0
PY=${PYTHON:-python3}
have_py() { command -v "$PY" >/dev/null 2>&1 && "$PY" -c "$1" >/dev/null 2>&1; }
if ! ei build tests/tools/czip.ei -o "$T/czip" > "$T/build.log" 2>&1; then
  echo "FAIL interop: build tests/tools/czip.ei"; cat "$T/build.log"; exit 1
fi
if ! have_py "import zlib"; then echo "skip interop: no $PY with zlib"; exit 0; fi
# the corpus
"$PY" -I - "$T" "$here" <<'EOF'
import os, random, sys
t, here = sys.argv[1], sys.argv[2]
random.seed(7)
text = b""
for root, _, files in os.walk(here):
    if "/target" in root or "/.git" in root:
        continue
    for f in sorted(files):
        if f.endswith((".ei", ".md", ".py", ".sh", ".toml")):
            text += open(os.path.join(root, f), "rb").read()
text = (text * (1500000 // max(len(text), 1) + 1))[:1500000]
open(t + "/text", "wb").write(text)
open(t + "/noise", "wb").write(bytes(random.getrandbits(8) for _ in range(200000)))
open(t + "/zeros", "wb").write(bytes(1000000))
mixed = b""
while len(mixed) < 600000:
    k = random.randrange(4)
    n = random.randrange(1, 4000)
    if k == 0:
        i = random.randrange(len(text) - n)
        mixed += text[i:i + n]
    elif k == 1:
        mixed += bytes([random.getrandbits(8)]) * n
    elif k == 2:
        mixed += bytes(random.getrandbits(8) for _ in range(n))
    elif len(mixed) > n:
        i = random.randrange(len(mixed) - n)
        mixed += mixed[i:i + n]
open(t + "/mixed", "wb").write(mixed[:600000])
open(t + "/empty", "wb").write(b"")
open(t + "/one", "wb").write(b"x")
EOF
CORPUS="text noise zeros mixed empty one"
check() { # name command...: ok if it succeeds
  what=$1; shift
  if "$@" > "$T/check.log" 2>&1; then echo "ok   interop $what"; else echo "FAIL interop $what"; head -5 "$T/check.log"; fail=1; fi
}
same() { cmp -s "$1" "$2"; }
# ---- gzip(1): both directions
if command -v gzip >/dev/null 2>&1; then
  ok=1
  for f in $CORPUS; do
    for l in 1 6 9; do
      gzip -$l -c "$T/$f" > "$T/s.gz"
      "$T/czip" gunzip "$T/s.gz" "$T/o" > "$T/log" 2>&1 && same "$T/o" "$T/$f" || { echo "FAIL interop: Eider gunzip of gzip -$l, $f"; head -3 "$T/log"; ok=0; fail=1; }
      "$T/czip" gzip "$T/$f" "$T/e.gz" $l > "$T/log" 2>&1 && gzip -dc "$T/e.gz" > "$T/o" 2>"$T/log" && same "$T/o" "$T/$f" || { echo "FAIL interop: gzip -d of Eider's level $l, $f"; head -3 "$T/log"; ok=0; fail=1; }
    done
  done
  [ $ok = 1 ] && echo "ok   interop gzip(1): levels 1, 6, 9 both ways on $CORPUS"
else
  echo "skip interop gzip(1): not installed"
fi
# ---- Python's zlib: zlib and raw deflate, both directions
cat > "$T/zl.py" <<'EOF'
import subprocess, sys, zlib
t, czip = sys.argv[1], sys.argv[2]
bad = 0
def run(*a):
    r = subprocess.run([czip] + list(a), capture_output=True, text=True)
    return r.returncode == 0
for f in sys.argv[3:]:
    data = open("%s/%s" % (t, f), "rb").read()
    for lv in (0, 1, 4, 6, 9):
        # zlib's streams, decoded by Eider
        for name, enc, cmd in (("zlib", lambda d: zlib.compress(d, lv), "unzlib"),
                               ("deflate", lambda d: (lambda c: c.compress(d) + c.flush())(zlib.compressobj(lv, zlib.DEFLATED, -15)), "inflate")):
            open(t + "/in", "wb").write(enc(data))
            if not run(cmd, t + "/in", t + "/out") or open(t + "/out", "rb").read() != data:
                print("FAIL interop: Eider %s of zlib level %d, %s" % (cmd, lv, f)); bad = 1
        # Eider's streams, decoded by zlib
        open(t + "/in", "wb").write(data)
        if not run("zlib", t + "/in", t + "/out", str(lv)) or zlib.decompress(open(t + "/out", "rb").read()) != data:
            print("FAIL interop: zlib.decompress of Eider's level %d, %s" % (lv, f)); bad = 1
        if not run("deflate", t + "/in", t + "/out", str(lv)):
            print("FAIL interop: Eider deflate level %d, %s" % (lv, f)); bad = 1
        else:
            d = zlib.decompressobj(-15)
            if d.decompress(open(t + "/out", "rb").read()) != data or not d.eof:
                print("FAIL interop: zlib raw inflate of Eider's level %d, %s" % (lv, f)); bad = 1
if not bad:
    print("ok   interop zlib: zlib and raw deflate, levels 0, 1, 4, 6, 9 both ways on " + " ".join(sys.argv[3:]))
sys.exit(bad)
EOF
if ! "$PY" -I "$T/zl.py" "$T" "$T/czip" $CORPUS; then fail=1; fi
# ---- Python's zstd (3.14+): both directions
if have_py "from compression import zstd"; then
  cat > "$T/zs.py" <<'EOF'
import subprocess, sys
from compression import zstd
t, czip = sys.argv[1], sys.argv[2]
bad = 0
def run(*a):
    r = subprocess.run([czip] + list(a), capture_output=True, text=True)
    return r.returncode == 0
P = zstd.CompressionParameter
for f in sys.argv[3:]:
    data = open("%s/%s" % (t, f), "rb").read()
    for lv in (-5, 1, 3, 9, 19):
        for csum in (0, 1):
            open(t + "/in", "wb").write(zstd.compress(data, options={P.compression_level: lv, P.checksum_flag: csum}))
            if not run("unzstd", t + "/in", t + "/out") or open(t + "/out", "rb").read() != data:
                print("FAIL interop: Eider unzstd of libzstd level %d (checksum %d), %s" % (lv, csum, f)); bad = 1
    open(t + "/in", "wb").write(data)
    for lv in (0, 1, 2, 3):
        if not run("zstd", t + "/in", t + "/out", str(lv)) or zstd.decompress(open(t + "/out", "rb").read()) != data:
            print("FAIL interop: libzstd of Eider's level %d, %s" % (lv, f)); bad = 1
if not bad:
    print("ok   interop zstd: libzstd levels -5, 1, 3, 9, 19 (with and without checksum) -> Eider, Eider levels 0 to 3 -> libzstd, on " + " ".join(sys.argv[3:]))
sys.exit(bad)
EOF
  if ! "$PY" -I "$T/zs.py" "$T" "$T/czip" $CORPUS; then fail=1; fi
elif command -v zstd >/dev/null 2>&1; then
  ok=1
  for f in $CORPUS; do
    for l in 1 3 19; do
      zstd -q -$l -c "$T/$f" > "$T/s.zst"
      "$T/czip" unzstd "$T/s.zst" "$T/o" > "$T/log" 2>&1 && same "$T/o" "$T/$f" || { echo "FAIL interop: Eider unzstd of zstd -$l, $f"; ok=0; fail=1; }
    done
    for l in 0 1 2 3; do
      "$T/czip" zstd "$T/$f" "$T/e.zst" $l > "$T/log" 2>&1 && zstd -q -dc "$T/e.zst" > "$T/o" 2>"$T/log" && same "$T/o" "$T/$f" || { echo "FAIL interop: zstd -d of Eider's level $l, $f"; ok=0; fail=1; }
    done
  done
  [ $ok = 1 ] && echo "ok   interop zstd(1): both ways on $CORPUS"
else
  echo "skip interop zstd: no Python 3.14 compression.zstd and no zstd(1)"
fi
exit $fail
