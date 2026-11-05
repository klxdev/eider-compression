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


# ---- hostile and malformed inputs, built by hand (bit level for deflate)
class Bits:
    def __init__(self):
        self.v = 0
        self.n = 0

    def put(self, value, count):  # LSB first
        self.v |= value << self.n
        self.n += count

    def huff(self, code, count):  # a Huffman code, MSB first
        for i in range(count - 1, -1, -1):
            self.put((code >> i) & 1, 1)

    def bytes(self):
        return self.v.to_bytes((self.n + 7) // 8, "little")


def fixed_lit(b, sym):
    if sym < 144:
        b.huff(0x30 + sym, 8)
    elif sym < 256:
        b.huff(0x190 + sym - 144, 9)
    elif sym < 280:
        b.huff(sym - 256, 7)
    else:
        b.huff(0xC0 + sym - 280, 8)


b = Bits(); b.put(1, 1); b.put(3, 2); add("bad_blocktype", b.bytes())
add("bad_stored", bytes([1, 5, 0, 0xFB, 0xFF, 1, 2, 3, 4, 5]))
b = Bits(); b.put(1, 1); b.put(1, 2); fixed_lit(b, ord("a")); fixed_lit(b, 257); b.huff(4, 5); fixed_lit(b, 256)
add("bad_dist", b.bytes())
b = Bits(); b.put(1, 1); b.put(1, 2); fixed_lit(b, 286); fixed_lit(b, 256)
add("bad_sym286", b.bytes())
b = Bits(); b.put(1, 1); b.put(1, 2); fixed_lit(b, ord("a")); fixed_lit(b, 257); b.huff(30, 5); fixed_lit(b, 256)
add("bad_dist30", b.bytes())
b = Bits(); b.put(1, 1); b.put(2, 2); b.put(31, 5); b.put(0, 5); b.put(0, 4)
add("bad_hlit", b.bytes())
# a dynamic block whose code length code is over-subscribed: HCLEN=4 lengths 1,1,1,1
b = Bits(); b.put(1, 1); b.put(2, 2); b.put(0, 5); b.put(0, 5); b.put(0, 4)
for l in (1, 1, 1, 1):
    b.put(l, 3)
add("bad_oversub", b.bytes())
# a dynamic block whose first code length is "repeat the previous" (code 16)
b = Bits(); b.put(1, 1); b.put(2, 2); b.put(0, 5); b.put(0, 5); b.put(0, 4)
for l in (1, 0, 1, 0):  # order 16,17,18,0: 16 and 0 get 1-bit codes
    b.put(l, 3)
b.huff(0, 1); b.put(0, 2)  # symbol 16 (code 0), 3 repeats
add("bad_repeat", b.bytes())

good = zlib.compress(INPUTS["hello"], 6)
add("bad_zlib_check", bytes([0x78, 0x9D]) + good[2:])
add("bad_zlib_method", bytes([0x77, 0x01]) + good[2:])
add("bad_zlib_adler", good[:-1] + bytes([good[-1] ^ 1]))
add("bad_zlib_trailing", good + b"x")
g = gz(INPUTS["hello"])
add("bad_gz_magic", bytes([0x1F, 0x8C]) + g[2:])
add("bad_gz_method", g[:2] + bytes([7]) + g[3:])
add("bad_gz_flags", g[:3] + bytes([0xE0]) + g[4:])
add("bad_gz_crc", g[:-8] + bytes([g[-8] ^ 1]) + g[-7:])
add("bad_gz_size", g[:-1] + bytes([g[-1] ^ 1]))
add("bad_gz_garbage", g + b"junk")
hg = gz(INPUTS["hello"], hcrc=True)
add("bad_gz_hcrc", hg[:10] + bytes([hg[10] ^ 1]) + hg[11:])

if zstd:
    z = zstd.compress(INPUTS["hello"], options={zstd.CompressionParameter.checksum_flag: 1})
    add("bad_zst_magic", bytes([0x27]) + z[1:])
    add("bad_zst_csum", z[:-1] + bytes([z[-1] ^ 1]))
    add("bad_zst_reserved", bytes([0x28, 0xB5, 0x2F, 0xFD, 0x08, 0x00]))
    # window descriptor 0xFF: a 2 TiB window
    add("bad_zst_window", bytes([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0xFF]))
    # single segment with a declared content size of 1 TiB (8-byte size)
    add("bad_zst_fcs", bytes([0x28, 0xB5, 0x2F, 0xFD, 0xE0]) + struct.pack("<Q", 1 << 40))
    add("bad_zst_dict", bytes([0x28, 0xB5, 0x2F, 0xFD, 0x01, 0x58, 0x07]))
    # a reserved block type, and a block larger than 128 KiB
    add("bad_zst_blocktype", bytes([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58]) + struct.pack("<I", 1 | (3 << 1) | (0 << 3))[:3])
    add("bad_zst_blocksize", bytes([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58]) + struct.pack("<I", 1 | (0 << 1) | (200000 << 3))[:3])
    # 200 RLE blocks of 128 KiB (25 MiB from 800 bytes), window 128 KiB
    rle = b"".join(struct.pack("<I", (1 if i == 199 else 0) | (1 << 1) | (131072 << 3))[:3] + b"\x00" for i in range(200))
    add("zst_rle_bomb", bytes([0x28, 0xB5, 0x2F, 0xFD, 0x00, 0x58]) + rle)
    # a frame header cut short, and a frame with no blocks
    add("bad_zst_short", bytes([0x28, 0xB5, 0x2F, 0xFD]))
    # a frame that declares 10 bytes but holds 5
    add("bad_zst_fcs_mismatch", bytes([0x28, 0xB5, 0x2F, 0xFD, 0x20, 10]) + struct.pack("<I", 1 | (0 << 1) | (5 << 3))[:3] + b"hello")

# a bomb for deflate/gzip: 5 MB of zeros
zb = bytes(5_000_000)
add("zeros_gz", gz(zb, 9))
add("zeros_raw", raw_deflate(zb, 9))

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
