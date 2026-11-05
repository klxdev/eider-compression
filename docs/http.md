# Compression in an HTTP server

eider-http is unchanged; this is how a handler uses eider-compression for `Content-Encoding`.
The snippets are compiled and run in `tests/readme_test.ei`.

## Request bodies

```eider
fn decode_body(content_encoding: List[u8], body: List[u8]) -> Result[List[u8], compression.Error] {
    match codec.format_of(content_encoding) {          // case-insensitive: gzip, x-gzip, deflate, zstd, identity
        Some(f) => codec.decode(f, body, compression.limit_output(8388608))
        None => Err(compression.error(compression.Unsupported, "unsupported Content-Encoding", 0))
    }
}
```

Map the error to a status: `Unsupported` is `415`; `TooLarge` and `RatioExceeded` are `413`; every
other kind (`Truncated`, `Corrupt`, `Checksum`, ...) is `400`. Set `max_output` to the largest body
the route accepts (the same number as the route's body limit), so a 4 KB gzip body cannot become
a 4 GB one. The ratio limit applies on top: by default 1100:1 after the first 4 MiB.

For a body that arrives in chunks, use `gzip.decoder(limits)` and `feed` each chunk; the limit is
enforced as the data arrives, and `finish()` reports a body cut short.

## Responses

```eider
fn pick(accept: str) -> Option[codec.Format] {
    codec.negotiate(accept.bytes(), List[codec.Zstd, codec.Gzip])   // the server's order of preference
}
```

`negotiate` honours q-values (`gzip;q=0.5`), `q=0` (forbidden), `*`, case, and ignores malformed
items. `None` means send the body as it is, without `Content-Encoding`. When you do compress, set
`Content-Encoding: gzip` (or `zstd`) and `Vary: Accept-Encoding`, and drop `Content-Length`
(chunked) or compute it from the compressed body.

A streaming response compresses piece by piece:

```eider
let mut enc = codec.encoder(codec.Gzip, 6)
let mut wire: List[u8] = List.new()
enc.write(piece, inout wire)       // send `wire`, then clear it
enc.flush(inout wire)              // optional: server-sent events need each message decodable
enc.finish(inout wire)             // the trailer: CRC-32 and size
```

Do not compress what is already compressed (images, archives) and small bodies (under about 1 KB),
and take care with secrets that share a compressed body with attacker-chosen text (BREACH).
