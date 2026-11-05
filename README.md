# eider-compression

Compression for Eider, written in Eider: **deflate** (RFC 1951), **zlib** (RFC 1950), **gzip**
(RFC 1952) and **zstd** (RFC 8878). Package `compression`; it needs no capability (no `io`, no
`clock`), so it runs anywhere a pure function can.

- Whole-buffer functions and streaming decoders and encoders that work in chunks.
- `std/stream` Readers and Writers (`compression.streams`) that decompress or compress as they go.
- CRC-32, Adler-32 and XXH64 (`compression.checksum`).
- **Hard decompression-bomb limits** (`compression.Limits`): maximum output, maximum ratio,
  zstd window, gzip header size. A limit stops the decoder before the output exists.
- **Hostile input never traps.** Every failure is a `Result` carrying a `compression.Error`
  (kind, message, input offset). The tests truncate and alter every byte of the test vectors and
  run a fuzzer under ASan and UBSan.
- Checked against the system's `gzip`, Python's `zlib` and `compression.zstd` (libzstd): what
  they compress, this decodes, and the other way round (`scripts/interop.sh`).

## Using it

`eider.toml` of your package:

```toml
[deps.compression]
git = "https://github.com/klxdev/eider-compression"
tag = "v0.7.0"
```

```eider
import compression
import compression.gzip as gzip
import compression.zstd as zstd
import core.sys

fn main() uses io {
    let text = sys.lit("hello hello hello hello hello")
    let packed = gzip.compress(text, 6)               // level 1..9
    match gzip.decompress(packed) {                   // Result[List[u8], compression.Error]
        Ok(back) => print("gzip: {back.len()} bytes back from {packed.len()}")
        Err(e) => print("gzip failed: {e}")
    }
    let z = zstd.compress(text, 3)                    // level 0..3
    match zstd.decompress(z) {
        Ok(back) => print("zstd: {back.len()} bytes back")
        Err(e) => print("zstd failed: {e}")
    }
}
```

(These examples are `tests/readme_test.ei`; they are compiled and run by `scripts/test.sh`.)

| module | what |
|---|---|
| `compression` | `Limits`, `limits()`, `unlimited()`, `limit_output(n)`, `Error`, `Kind` |
| `compression.deflate` | raw deflate: `inflate`, `inflate_with`, `Inflater`, `deflate`, `Deflater` |
| `compression.zlib` | `compress`, `decompress`, `Decoder`, `Encoder`, preset dictionaries on decode |
| `compression.gzip` | `compress`, `decompress`, `Decoder`, `Encoder` (name, comment, mtime), `Header` |
| `compression.zstd` | `compress`, `decompress`, `Decoder`, `Encoder` |
| `compression.codec` | one interface over all of them, by Content-Encoding name; `negotiate` for Accept-Encoding |
| `compression.streams` | `DecodeReader[R]` and `EncodeWriter[W]` for `std.stream` |
| `compression.checksum` | `crc32`, `adler32`, `xxh64` and their incremental forms |

## Streams

A decoder is fed in pieces of any size (one byte at a time works) and appends to a `List` you own:

```eider
fn decode_pieces(pieces: List[List[u8]]) -> Result[List[u8], compression.Error] {
    let mut dec = gzip.decoder(compression.limit_output(1000000))
    let mut out: List[u8] = List.new()
    for piece in pieces {
        dec.feed(piece, inout out)?
    }
    dec.finish()?                 // Truncated if the stream was cut short
    Ok(out)
}
```

An encoder is the mirror: `enc.write(chunk, inout out)`, `enc.flush(inout out)` (a sync flush: all
input so far can be decoded, a message boundary), `enc.finish(inout out)`.

`compression.streams` adapts both to `std.stream`: `decode_reader(reader, format, limits)` is a
Reader whose bytes are the decompressed bytes of another Reader; `encode_writer(writer, format,
level)` is a Writer that compresses what is written into another (`close()` writes the trailer).

```eider
let mut w = streams.encode_writer(stream.buffer(), codec.Gzip, 6)
w.write(sys.lit("line one\n"))
w.write(sys.lit("line two\n"))
w.close()
let mut r = streams.decode_reader(stream.reader(w.inner().bytes()), codec.Gzip, compression.limits())
r.read_text()          // "line one\nline two\n"
```

A truncated stream reads as `UnexpectedEof`, any other error as `InvalidData`.

## Limits

`compression.limits()` (the default of every whole-buffer function and decoder) allows

| field | default | meaning |
|---|---|---|
| `max_output` | 64 MiB | most bytes a decoder produces |
| `max_ratio` | 1100 | most output bytes per input byte fed... |
| `ratio_floor` | 4 MiB | ...but at least this much is always allowed |
| `max_window` | 8 MiB | most zstd window (and so memory) a frame may ask for |
| `max_header` | 64 KiB | most bytes of a gzip header (name, comment, extra) |

The output cap at any moment is the smaller of `max_output` and `max(ratio_floor, max_ratio *
bytes_fed)`. Deflate cannot exceed about 1032:1, so 1100 never refuses a legitimate stream; a
bomb, which is a few kilobytes that expand to gigabytes, hits the cap after at most a few
megabytes of output and the decoder returns `TooLarge` or `RatioExceeded` with the offset. Use
`compression.limit_output(n)` for a different `max_output` or `compression.unlimited()` for
trusted data. The check is made per block (per 258-byte match for deflate), not after the fact:
the output list never grows past the cap.

## Formats and what is done

- **deflate, zlib, gzip: complete.** Decode: stored, fixed and dynamic blocks, a 10-bit
  table-driven Huffman decoder, resumable at any byte boundary, preset dictionaries (zlib),
  multi-member gzip (RFC 1952 concatenation, zero padding ignored), header CRC, FEXTRA, FNAME and
  FCOMMENT. Encode: levels 1..9 with zlib's parameters (greedy 1-3, lazy 4-9; hash chains), stored,
  fixed or dynamic blocks by the computed size, length-limited code lengths, sync flush.
- **zstd decode: complete for the format.** Raw, RLE and compressed blocks, Huffman literals
  (1 and 4 streams, FSE-coded and direct weights, treeless), the sequence section with
  predefined, RLE, FSE and repeat tables, repeat offsets, multiple frames, skippable frames,
  the content checksum (XXH64), frame content size and window limits. Dictionaries (a frame with a
  dictionary id) are refused with `Dictionary`.
- **zstd encode: levels 0..3.** Level 0 stores (raw blocks, RLE for runs). Levels 1-3 find matches
  with a hash chain over a 128 KiB window, emit literals raw (not Huffman-coded) and code the
  sequences with the predefined FSE tables, with a raw/RLE fallback per block. Frames carry the
  content checksum. libzstd decodes all of it; the compression ratio is lower than libzstd's at
  the same level (see the table) because there is no Huffman literal coding, no
  custom FSE tables, no optimal parser. Dictionaries are not supported.
- **Not done:** zstd dictionaries (decode and encode), zstd Huffman literal encoding, zstd levels
  above 3, multi-threaded compression, deflate64, brotli.

## Throughput

On 8 MB of source text (`scripts/bench.sh`, one core, `-O2` through `eider build`), MB/s of
uncompressed data; the reference rows are Python's zlib and libzstd on the same machine.

| | ratio | encode | decode |
|---|---|---|---|
| deflate 1 | 3.15 | 77 | 222 |
| deflate 3 | 3.37 | 67 | 222 |
| deflate 6 | 3.72 | 33 | 229 |
| deflate 9 | 3.76 | 18 | 229 |
| gzip 6 | 3.72 | 32 | 163 |
| zstd 0 (stored) | 1.00 | 205 | 250 |
| zstd 1 | 2.67 | 24 | 157 |
| zstd 3 | 3.07 | 18 | 182 |
| (python zlib 6) | 3.76 | 76 | 611 |
| (libzstd 3) | 3.83 | 265 | 735 |

The Eider codecs are 2-4 times slower than zlib and libzstd at the same ratio, in line with
what safe, checked, copy-on-write code costs; the output is byte-compatible.

## HTTP: Content-Encoding

eider-http is not changed by this library. `docs/http.md` shows the three places it is used:

- **Responses**: `codec.negotiate(accept_encoding_bytes, List[codec.Zstd, codec.Gzip])` returns
  the best coding the client accepts (q-values, `*`, `q=0`), then a streaming `Encoder` compresses
  the body piece by piece; set `Content-Encoding` and `Vary: Accept-Encoding`.
- **Request bodies**: `codec.format_of(content_encoding)` then `codec.decode(f, body, limits)`; a
  `TooLarge` or `RatioExceeded` error is a `413`, any other error a `400`, an unknown coding `415`.
- **Bombs**: always pass explicit limits for data from the network.

## Developing

```sh
sh scripts/test.sh          # every tests/*.ei, TSan and ASan+UBSan runs, interop (gzip, python)
sh scripts/bench.sh         # the throughput table
sh scripts/version.sh check # VERSION, eider.toml and the changelog agree
```

`tests/vectors.ei` is generated by `scripts/gen-vectors.py` (system tools only; the output is
committed, so the tests need nothing but the toolchain). `tests/tools/czip.ei` is a small command
line (`czip gunzip < x.gz`) that `scripts/interop.sh` drives.

## Versions

Before 1.0 the library keeps the MAJOR.MINOR of the Eider toolchain it is built for (`eider =
"0.7"`); `scripts/version.sh` and eider-lang's `scripts/version.sh check-siblings` verify it.
See `CHANGELOG.md`.
