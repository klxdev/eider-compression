#!/usr/bin/env python3
"""Regenerates tests/vectors.ei: small test vectors made by the reference implementations.

    python3 scripts/gen-vectors.py > tests/vectors.ei

deflate, zlib and gzip come from Python's zlib (zlib 1.x), zstd from Python 3.14's
compression.zstd (libzstd). The inputs are fixed; the outputs only change with those libraries.
Committed so the tests need no tools; scripts/interop.sh checks against live tools.
"""
import struct
import sys
import zlib

try:
    from compression import zstd
except ImportError:
    zstd = None


def lcg(seed):
    s = seed
    while True:
        s = (s * 6364136223846793005 + 1442695040888963407) & 0xFFFFFFFFFFFFFFFF
        yield s >> 33


WORDS = ["the", "quick", "brown", "fox", "jumps", "over", "lazy", "dog", "eider", "duck", "down",
         "compression", "stream", "block", "window", "literal", "match", "offset", "length", "table"]


def text(n, seed):
    g = lcg(seed)
    out = b""
    while len(out) < n:
        out += WORDS[next(g) % len(WORDS)].encode() + (b"\n" if next(g) % 9 == 0 else b" ")
    return out[:n]


INPUTS = {
    "empty": b"",
    "one": b"a",
    "hello": b"Hello, hello, hello, world! " * 10,
    "text": text(3000, 7),
    "zeros": bytes(5000),
    "bytes": bytes(range(256)) * 3,
}


def hexs(b):
    return b.hex()


def raw_deflate(data, level, strategy=zlib.Z_DEFAULT_STRATEGY):
    c = zlib.compressobj(level, zlib.DEFLATED, -15, 9, strategy)
    return c.compress(data) + c.flush()


def gz(data, level=6, name=None, comment=None, extra=None, hcrc=False, mtime=0):
    flg = 0
    hdr = b""
    if extra is not None:
        flg |= 4
    if name is not None:
        flg |= 8
    if comment is not None:
        flg |= 16
    if hcrc:
        flg |= 2
    h = struct.pack("<BBBBIBB", 0x1F, 0x8B, 8, flg, mtime, 0, 3)
    if extra is not None:
        h += struct.pack("<H", len(extra)) + extra
    if name is not None:
        h += name + b"\0"
    if comment is not None:
        h += comment + b"\0"
    if hcrc:
        h += struct.pack("<H", zlib.crc32(h) & 0xFFFF)
    body = raw_deflate(data, level)
    return h + body + struct.pack("<II", zlib.crc32(data), len(data) & 0xFFFFFFFF)


vectors = []  # (name, hex)


def add(name, data):
    vectors.append((name, hexs(data)))


for k in ["empty", "one", "hello", "text", "zeros", "bytes"]:
    d = INPUTS[k]
    add("raw0_" + k, raw_deflate(d, 0))
    add("raw1_" + k, raw_deflate(d, 1))
    add("raw6_" + k, raw_deflate(d, 6))
    add("raw9_" + k, raw_deflate(d, 9))
    add("fixed_" + k, raw_deflate(d, 6, zlib.Z_FIXED))
    add("huff_" + k, raw_deflate(d, 6, zlib.Z_HUFFMAN_ONLY))
    add("rle_" + k, raw_deflate(d, 6, zlib.Z_RLE))
    add("zlib6_" + k, zlib.compress(d, 6))
    add("gz6_" + k, gz(d, 6))
    if zstd:
        add("zst1_" + k, zstd.compress(d, options={zstd.CompressionParameter.compression_level: 1, zstd.CompressionParameter.checksum_flag: 1}))
        add("zst3_" + k, zstd.compress(d, level=3))
        add("zst19_" + k, zstd.compress(d, options={zstd.CompressionParameter.compression_level: 19, zstd.CompressionParameter.checksum_flag: 1}))

# framing variants
h = INPUTS["hello"]
add("gz_name", gz(h, name=b"hello.txt"))
add("gz_all", gz(h, name=b"hello.txt", comment=b"a comment", extra=b"XY\x04\x00abcd", hcrc=True, mtime=1700000000))
add("gz_hcrc", gz(h, hcrc=True))
add("gz_two", gz(INPUTS["hello"]) + gz(INPUTS["text"]))
add("gz_pad", gz(h) + bytes(8))
add("zlib_dict_input", b"Hello, hello, hello, world! ")
dct = b"Hello, hello, hello, world! "
c = zlib.compressobj(6, zlib.DEFLATED, 15, 9, zlib.Z_DEFAULT_STRATEGY, dct)
add("zlib_dict", c.compress(h) + c.flush())
add("zlib_level1", zlib.compress(h, 1))
add("zlib_level9", zlib.compress(h, 9))
if zstd:
    add("zst_two_frames", zstd.compress(h) + zstd.compress(INPUTS["text"]))
    add("zst_skippable", bytes.fromhex("502a4d18") + struct.pack("<I", 5) + b"skip!" + zstd.compress(h))
    # a frame with a 4-stream Huffman literals section needs a bigger input
    big = text(40000, 11)
    add("zst3_big", zstd.compress(big, level=3))
    add("zst19_big", zstd.compress(big, options={zstd.CompressionParameter.compression_level: 19, zstd.CompressionParameter.checksum_flag: 1}))
    add("raw6_big", raw_deflate(big, 6))

print("//! Test vectors made by the reference implementations (scripts/gen-vectors.py): zlib's deflate,")
print("//! zlib and gzip framing, and libzstd. Each is a hex string; `v(name)` decodes it.")
print()
print("import core.sys")
print("import std.encoding")
print()
print("pub fn v(name: str) -> List[u8] { vs(String.from(name)) }")
print()
print("pub fn vs(name: String) -> List[u8] {")
for n, hx in vectors:
    print('    if name == String.from("%s") { return unhex("%s") }' % (n, hx))
print('    List.new()')
print("}")
print()
print("fn unhex(s: str) -> List[u8] {")
print("    match encoding.unhex(sys.lit(s)) {")
print("        Ok(b) => b")
print("        Err(_) => List.new()")
print("    }")
print("}")
print()
print("/// The names of every vector.")
print("pub fn names() -> List[str] {")
print("    List[" + ", ".join('"%s"' % n for n, _ in vectors) + "]")
print("}")
