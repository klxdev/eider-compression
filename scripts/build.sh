#!/bin/sh
# Fetch eider-compression's dependencies and check every module against the Eider toolchain.
#
#   sh scripts/build.sh
#
# The toolchain, its version check and the local overrides of the dependencies are
# scripts/env.sh's: EIDER_TOOLCHAIN, else the one `eider` picks; EIDER_PKG_OVERRIDE, EIDER_<NAME>.
# Writes eider.lock here and in each package under examples/ (`eider-pkg fetch`; a library
# doesn't commit its lock), then `eiderc check`s a program importing every module (a module
# can't be checked as a program of its own). Exit 2: no usable toolchain.
set -e
here=$(cd "$(dirname "$0")/.." && pwd -P)
. "$here/scripts/env.sh"
mkdir -p "$here/target"
for p in "$here" "$here"/examples/*; do
  [ -f "$p/eider.toml" ] || continue
  grep -q '^\[deps\.' "$p/eider.toml" || continue
  if ! eider_pkg -C "$p" fetch > "$here/target/fetch.log" 2>&1; then
    echo "FAIL eider-pkg fetch in $p (EIDER_PKG_OVERRIDE=$EIDER_PKG_OVERRIDE)"
    cat "$here/target/fetch.log"
    exit 1
  fi
done
# a program that imports every module of the package by name, as its users do
probe=$here/target/check_modules.ei
: > "$probe"
for f in "$here"/*.ei; do
  m=$(basename "$f" .ei)
  if [ "$m" = "$pkg_name" ]; then echo "import $pkg_name" >> "$probe"; else echo "import $pkg_name.$m" >> "$probe"; fi
done
printf '\nfn main() {}\n' >> "$probe"
ei check "$probe" > "$here/target/check.log" 2>&1 || { echo "FAIL eiderc check (every module: $probe)"; cat "$here/target/check.log"; exit 1; }
echo "built eider-compression $mine (Eider $theirs at $toolchain; $chosen)"
