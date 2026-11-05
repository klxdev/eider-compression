# Changelog

## 0.7.0

First version (Eider 0.7.3, klxdev/eider-lang #37).

- deflate, zlib and gzip: decode and encode (levels 1..9), streaming and whole-buffer,
  CRC-32 and Adler-32, multi-member gzip, preset dictionaries on decode, sync flush.
- zstd: decode (all block types, Huffman and FSE, repeat offsets, skippable and multiple frames,
  XXH64 content checksum); encode at levels 0..3 (raw/RLE blocks, hash-chain matches with
  predefined FSE tables, raw literals). Not done: dictionaries, Huffman literal coding, levels
  above 3.
- `compression.Limits`: maximum output, maximum ratio, zstd window, gzip header size. Strict
  `Result` errors with a kind and an input offset; hostile input never traps.
- `compression.codec`: format by Content-Encoding name, auto-detection, `negotiate` for
  Accept-Encoding. `compression.streams`: `std.stream` Reader and Writer adapters.
- Tests: upstream-tool vectors, 2500 round trips, hostile and truncated inputs, a fuzzer, a
  concurrency test, TSan and ASan+UBSan runs, interop with gzip(1), Python zlib and libzstd.
