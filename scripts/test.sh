#!/bin/sh
# eider-compression's tests.
#
#   sh scripts/test.sh             scripts/build.sh, then every test
#   NOBUILD=1 sh scripts/test.sh   skip scripts/build.sh (the locks are already fetched)
#   NOINTEROP=1 sh scripts/test.sh skip scripts/interop.sh
#
# Every tests/*.ei is run with the toolchain's compiler (`eider run`) and its output compared with
# the .out next to it. The tests in TSAN (they use threads) are then built once under
# ThreadSanitizer and run once each, and the tests in ASAN once under AddressSanitizer and
# UBSan (the decoders take hostile input), each when $CC can build such a program (else `skip`).
# scripts/interop.sh then checks the codecs against the system's gzip and Python's zlib and zstd,
# when they are there. Prints `ok   <test>` or `FAIL <test>` with a diff, then `ALL OK`; exits 1
# on a failure, 2 when there is no usable toolchain (scripts/env.sh).
TSAN="tests/concurrent_test.ei"
ASAN="tests/vectors_test.ei tests/hostile_test.ei tests/fuzz_test.ei tests/stream_test.ei tests/roundtrip_test.ei"
here=$(cd "$(dirname "$0")/.." && pwd -P)
if [ -z "$NOBUILD" ]; then
  sh "$here/scripts/build.sh" || exit $?
fi
. "$here/scripts/env.sh"
cd "$here" || exit 1
fail=0
for f in tests/*.ei; do
  [ -f "$f" ] && [ -f "${f%.ei}.out" ] || continue
  got=$(ei run "$f" 2>&1 < /dev/null)
  if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f"; else echo "FAIL $f"; echo "$got" | diff "${f%.ei}.out" - | head -10; fail=1; fi
done
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
sanitized() { # <name> <flags> <tests>
  name=$1; flags=$2; shift 2
  printf 'int main(void) { return 0; }\n' > "$T/probe.c"
  if ${CC:-cc} $flags -o "$T/probe" "$T/probe.c" 2>/dev/null && "$T/probe"; then
    for f in "$@"; do
      if ! (EIDER_CACHE=off EIDER_CFLAGS="$flags -g"; export EIDER_CACHE EIDER_CFLAGS; ei build "$f" -o "$T/t") > "$T/log" 2>&1; then
        echo "FAIL $f ($name): build"; cat "$T/log"; fail=1; continue
      fi
      got=$(TSAN_OPTIONS="halt_on_error=1 exitcode=66" ASAN_OPTIONS="exitcode=66" UBSAN_OPTIONS="halt_on_error=1 exitcode=66" "$T/t" < /dev/null 2>&1)
      if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f ($name)"; else echo "FAIL $f ($name)"; echo "$got" | diff "${f%.ei}.out" - | head -20; fail=1; fi
    done
  else
    echo "skip $name runs: ${CC:-cc} cannot build a $flags program"
  fi
}
sanitized tsan "-fsanitize=thread" $TSAN
sanitized asan "-fsanitize=address,undefined -fno-sanitize-recover=undefined" $ASAN
if [ -z "$NOINTEROP" ] && [ -f "$here/scripts/interop.sh" ]; then
  if ! sh "$here/scripts/interop.sh"; then fail=1; fi
fi
[ $fail = 0 ] && echo "ALL OK"
exit $fail
