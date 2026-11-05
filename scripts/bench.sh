#!/bin/sh
# Throughput of the codecs on a corpus of real text (the .ei, .md, .rs, .ts, ... files under the
# directories given, 8 MB at most), as MB/s of uncompressed data, and the compressed size. The
# reference numbers are Python's zlib and zstd on the same machine, for scale.
#
#   sh scripts/bench.sh [dir...]        (default: this repository's parent directory)
#
# Needs the toolchain (scripts/env.sh) and python3.
here=$(cd "$(dirname "$0")/.." && pwd -P)
. "$here/scripts/env.sh"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cd "$here" || exit 1
ei build tests/tools/czip.ei -o "$T/czip" > "$T/build.log" 2>&1 || { cat "$T/build.log"; exit 1; }
dirs=${*:-$(dirname "$here")}
python3 -I - "$T" $dirs <<'EOF'
import os, sys
t = sys.argv[1]
out = bytearray(); seen = set()
for root in sys.argv[2:]:
    for r, ds, fs in os.walk(root):
        ds[:] = [d for d in ds if d not in ("target", "node_modules", ".git", ".claude", "dist")]
        for f in sorted(fs):
            if f.endswith((".md", ".ei", ".ts", ".rs", ".py", ".toml", ".json", ".js", ".c", ".h")):
                try: b = open(os.path.join(r, f), "rb").read()
                except OSError: continue
                if len(b) < 200 or hash(b) in seen: continue
                seen.add(hash(b)); out += b
                if len(out) >= 8_000_000: break
        if len(out) >= 8_000_000: break
    if len(out) >= 8_000_000: break
open(t + "/corpus", "wb").write(bytes(out[:8_000_000]))
EOF
python3 -I - "$T" "$T/czip" <<'EOF'
import subprocess, sys, time, zlib
t, czip = sys.argv[1], sys.argv[2]
data = open(t + "/corpus", "rb").read()
mb = len(data) / 1e6
def ms(*a):
    r = subprocess.run([czip] + list(a), capture_output=True, text=True)
    return int(r.stdout.split("ms ")[1].split()[0]) if "ms " in r.stdout else None
def rate(v): return "%7.1f" % (mb / (v / 1000)) if v else "      -"
try:
    from compression import zstd
except ImportError:
    zstd = None
print("corpus: %d bytes\n" % len(data))
print("%-22s %10s %7s %12s %12s" % ("", "size", "ratio", "encode MB/s", "decode MB/s"))
def tm(f):
    s = time.perf_counter(); r = f(); return r, (time.perf_counter() - s) * 1000
for lv in (1, 3, 6, 9):
    enc = ms("deflate", t + "/corpus", t + "/c", str(lv))
    size = len(open(t + "/c", "rb").read())
    dec = ms("inflate", t + "/c", t + "/o")
    z, zms = tm(lambda: (lambda c: c.compress(data) + c.flush())(zlib.compressobj(lv, zlib.DEFLATED, -15)))
    _, zdms = tm(lambda: zlib.decompressobj(-15).decompress(z))
    print("%-22s %10d %7.3f %12s %12s" % ("deflate level %d" % lv, size, len(data) / size, rate(enc), rate(dec)))
    print("%-22s %10d %7.3f %12s %12s" % ("  (python zlib %d)" % lv, len(z), len(data) / len(z), rate(zms), rate(zdms)))
enc = ms("gzip", t + "/corpus", t + "/c", "6")
size = len(open(t + "/c", "rb").read())
dec = ms("gunzip", t + "/c", t + "/o")
print("%-22s %10d %7.3f %12s %12s" % ("gzip level 6", size, len(data) / size, rate(enc), rate(dec)))
if zstd:
    P = zstd.CompressionParameter
    for lv in (0, 1, 2, 3):
        enc = ms("zstd", t + "/corpus", t + "/c", str(lv))
        size = len(open(t + "/c", "rb").read())
        dec = ms("unzstd", t + "/c", t + "/o")
        print("%-22s %10d %7.3f %12s %12s" % ("zstd level %d" % lv, size, len(data) / size, rate(enc), rate(dec)))
    for lv in (1, 3, 19):
        c, cms = tm(lambda: zstd.compress(data, options={P.compression_level: lv, P.checksum_flag: 1}))
        _, dms = tm(lambda: zstd.decompress(c))
        print("%-22s %10d %7.3f %12s %12s" % ("  (libzstd %d)" % lv, len(c), len(data) / len(c), rate(cms), rate(dms)))
    open(t + "/c", "wb").write(zstd.compress(data, level=3))
    print("%-22s %10s %7s %12s %12s" % ("unzstd of libzstd 3", "", "", "", rate(ms("unzstd", t + "/c", t + "/o"))))
EOF
