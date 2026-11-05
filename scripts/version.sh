#!/bin/sh
# eider-compression's version: VERSION, MAJOR.MINOR.PATCH (CHANGELOG.md).
#
#   scripts/version.sh            print the version
#   scripts/version.sh check      eider.toml's `version` is VERSION and its `eider` VERSION's
#                                 MAJOR.MINOR
#   scripts/version.sh sync       write VERSION into eider.toml (`version`, `eider`)
#
# Before 1.0 the MAJOR.MINOR is the Eider toolchain's (eider-lang's VERSION) and the PATCH
# this package's own. eider-lang's `scripts/version.sh bump` writes VERSION here and runs
# `sync`; its `check-siblings` runs `check`; scripts/env.sh refuses a toolchain of another
# MAJOR.MINOR.
cd "$(dirname "$0")/.." || exit 1
v=$(tr -d ' \n' < VERSION 2>/dev/null)
echo "$v" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' || { echo "version.sh: VERSION must be MAJOR.MINOR.PATCH, not \`$v\`" >&2; exit 1; }
series=${v%.*}
of_toml() { sed -n "s/^$1 = \"\(.*\)\"\$/\1/p" eider.toml | head -1; }
case "${1:-}" in
  "") echo "$v" ;;
  check)
    bad=0
    [ "$(of_toml version)" = "$v" ] || { echo "FAIL eider-compression version: eider.toml's version is \`$(of_toml version)\`, VERSION says $v" >&2; bad=1; }
    [ "$(of_toml eider)" = "$series" ] || { echo "FAIL eider-compression version: eider.toml's eider is \`$(of_toml eider)\`, VERSION says $series" >&2; bad=1; }
    exit $bad ;;
  sync)
    awk -v v="$v" -v s="$series" '
      !dv && /^version = "/ { print "version = \"" v "\""; dv = 1; next }
      !de && /^eider = "/ { print "eider = \"" s "\""; de = 1; next }
      { print }' eider.toml > eider.toml.tmp && mv eider.toml.tmp eider.toml
    echo "eider-compression $v: eider.toml" ;;
  *) echo "usage: scripts/version.sh [check | sync]" >&2; exit 2 ;;
esac
