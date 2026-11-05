#!/bin/sh
# eider-compression's tests.
#
#   sh scripts/test.sh             scripts/build.sh, then every test
#   NOBUILD=1 sh scripts/test.sh   skip scripts/build.sh (the locks are already fetched)
#
# Every tests/*.ei and examples/*/tests/*.ei is run with the toolchain's compiler (`eider run`) and its
# output compared with the .out next to it. The tests in TSAN (they use threads) are then
# built once under ThreadSanitizer and run once each, when $CC can build a TSan program
# (else `skip`). Prints `ok   <test>` or `FAIL <test>` with a diff, then `ALL OK`; exits 1
# on a failure, 2 when there is no usable toolchain (scripts/env.sh).
TSAN=""
here=$(cd "$(dirname "$0")/.." && pwd -P)
if [ -z "$NOBUILD" ]; then
  sh "$here/scripts/build.sh" || exit $?
fi
. "$here/scripts/env.sh"
cd "$here" || exit 1
fail=0
for f in tests/*.ei examples/*/tests/*.ei; do
  [ -f "$f" ] && [ -f "${f%.ei}.out" ] || continue
  got=$(ei run "$f" 2>&1 < /dev/null)
  if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f"; else echo "FAIL $f"; echo "$got" | diff "${f%.ei}.out" - | head -10; fail=1; fi
done
if [ -n "$TSAN" ]; then
  T=$(mktemp -d)
  trap 'rm -rf "$T"' EXIT
  printf 'int main(void) { return 0; }\n' > "$T/probe.c"
  if ${CC:-cc} -fsanitize=thread -o "$T/probe" "$T/probe.c" 2>/dev/null && "$T/probe"; then
    for f in $TSAN; do
      if ! (EIDER_CACHE=off EIDER_CFLAGS="-fsanitize=thread -g"; export EIDER_CACHE EIDER_CFLAGS; ei build "$f" -o "$T/t") > "$T/log" 2>&1; then
        echo "FAIL $f (tsan): build"; cat "$T/log"; fail=1; continue
      fi
      got=$(TSAN_OPTIONS="halt_on_error=1 exitcode=66" "$T/t" < /dev/null 2>&1)
      if [ "$got" = "$(cat "${f%.ei}.out")" ]; then echo "ok   $f (tsan)"; else echo "FAIL $f (tsan)"; echo "$got" | diff "${f%.ei}.out" - | head -20; fail=1; fi
    done
  else
    echo "skip tsan runs ($TSAN): ${CC:-cc} cannot build a -fsanitize=thread program"
  fi
fi
[ $fail = 0 ] && echo "ALL OK"
exit $fail
