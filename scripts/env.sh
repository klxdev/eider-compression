# Sourced by scripts/build.sh and scripts/test.sh (with `here` set to this repository): the
# Eider toolchain, the version check, and the local overrides of the git dependencies.
#
# The toolchain is the one `eider` (eider-lang's docs/site/tooling/eider.md) picks, the first
# of:
#   1. $EIDER_TOOLCHAIN: a toolchain directory (bin/eiderc) or an eider-lang checkout
#      (scripts/ei), for testing against unreleased work (eider-lang's scripts/check-tools.sh
#      sets it to its checkout);
#   2. `eider toolchain show --json` here: the installed toolchain for eider.toml's
#      `eider = "MAJOR.MINOR"` (its newest installed patch; else eider's default);
#   3. neither: exit 2, saying to install eider (install.sh).
# Its VERSION must have the MAJOR.MINOR that eider.toml's `eider` names, which is this
# package's own MAJOR.MINOR (VERSION): before 1.0 a MINOR may break compatibility, so each
# library release goes with one toolchain series (CHANGELOG.md). Anything else exits 2 with
# the reason. The compiler and eider-pkg then run as `ei <args>` and `eider_pkg <args>`:
# through `eider` with EIDER_TOOLCHAIN set to that toolchain, or, without `eider` on the PATH
# (case 1 only), the toolchain's own programs with EIDER_ROOT set as eider sets it.
#
# Dependencies are git packages (eider.toml). To work offline, against checkouts of them that
# may have uncommitted edits, eider-pkg takes a dependency from a local directory instead of
# its repository when EIDER_PKG_OVERRIDE names it (`name=dir`, comma separated; eider-lang's
# docs/site/tooling/eider-pkg.md). This sets it for each of DEPS (every git package in the
# graph, transitive ones included) that it doesn't name yet: EIDER_<NAME> when set (e.g.
# EIDER_JSON), else the sibling checkout ../eider-<name> when there is one, else, when the
# toolchain is an eider-lang checkout whose vendor.lock pins it, that pinned release in
# $toolchain/.vendor/<name> (fetched there and hash-checked by its scripts/vendor.sh on first
# use). A dependency with none of these is fetched from its repository (network).
# DEPS: the git packages in this repository's dependency graph (transitive ones included).
DEPS=""

die() { echo "$(basename "$0"): $*" >&2; exit 2; }
install_hint="install eider (gh release download --repo klxdev/eider-lang --pattern install.sh && sh install.sh --toolchain; eider-lang's docs/site/tooling/eider.md), or set EIDER_TOOLCHAIN to an Eider toolchain or an eider-lang checkout"
if [ -n "${EIDER_TOOLCHAIN:-}" ]; then
  toolchain=$(cd "$EIDER_TOOLCHAIN" 2>/dev/null && pwd -P) || die "EIDER_TOOLCHAIN=$EIDER_TOOLCHAIN: no such directory"
  chosen="EIDER_TOOLCHAIN"
elif command -v eider >/dev/null 2>&1; then
  shown=$(cd "$here" && eider toolchain show --json 2>/dev/null) || true
  toolchain=$(printf '%s\n' "$shown" | sed -n 's/^{.*"path":"\([^"]*\)".*/\1/p')
  if [ -z "$toolchain" ]; then
    why=$(printf '%s\n' "$shown" | sed -n 's/^{"error":"\(.*\)"}$/\1/p' | sed 's/\\"/"/g')
    die "eider found no toolchain for $here: ${why:-eider toolchain show --json printed \`$shown\`}"
  fi
  chosen="eider toolchain show: $(printf '%s\n' "$shown" | sed -n 's/.*"why":"\(.*\)"}$/\1/p' | sed 's/\\"/"/g')"
else
  die "no Eider toolchain: no \`eider\` on the PATH and no EIDER_TOOLCHAIN; $install_hint"
fi
# a checkout: its seed is seed/eiderc.wasm since eider-lang 0.2 (seed/eiderc.c before)
if [ -x "$toolchain/scripts/ei" ] && { [ -f "$toolchain/seed/eiderc.wasm" ] || [ -f "$toolchain/seed/eiderc.c" ]; }; then
  tc_eiderc=$toolchain/scripts/ei; tc_pkg=$toolchain/scripts/eider-pkg
elif [ -x "$toolchain/bin/eiderc" ]; then
  tc_eiderc=$toolchain/bin/eiderc; tc_pkg=$toolchain/bin/eider-pkg
else
  die "$toolchain ($chosen) is neither an Eider toolchain (bin/eiderc) nor an eider-lang checkout (scripts/ei)"
fi
toml_value() { sed -n "s/^$1 = \"\(.*\)\"\$/\1/p" "$here/eider.toml" | head -1; }
pkg_name=$(toml_value name)
mine=$(tr -d ' \n' < "$here/VERSION")
series=$(toml_value eider)
[ "$(toml_value version)" = "$mine" ] || die "VERSION is $mine but eider.toml's version is $(toml_value version)"
[ "${mine%.*}" = "$series" ] || die "VERSION is $mine but eider.toml says eider = \"$series\" (they share MAJOR.MINOR)"
theirs=
[ -f "$toolchain/VERSION" ] && theirs=$(tr -d ' \n' < "$toolchain/VERSION")
[ -n "$theirs" ] || die "the toolchain at $toolchain has no VERSION (it is older than Eider 0.1.0); eider-$pkg_name $mine needs Eider $series.x"
[ "${theirs%.*}" = "$series" ] || die "eider-$pkg_name $mine needs an Eider $series.x toolchain, but $toolchain ($chosen) is Eider $theirs; \`eider toolchain install $series\`, or use the eider-$pkg_name release made for Eider ${theirs%.*} (CHANGELOG.md)"
EIDER_TOOLCHAIN=$toolchain
EIDER_ROOT=$toolchain
export EIDER_TOOLCHAIN EIDER_ROOT
if command -v eider >/dev/null 2>&1; then
  ei() { eider eiderc "$@"; }
  eider_pkg() { eider eider-pkg "$@"; }
else
  EIDERC=$tc_eiderc
  export EIDERC
  ei() { "$tc_eiderc" "$@"; }
  eider_pkg() { "$tc_pkg" "$@"; }
fi

for d in $DEPS; do
  case ",$EIDER_PKG_OVERRIDE," in *",$d="*) continue ;; esac
  var=EIDER_$(echo "$d" | tr 'a-z' 'A-Z')
  eval "dir=\${$var:-}"
  if [ -z "$dir" ] && [ -f "$here/../eider-$d/eider.toml" ]; then dir=$here/../eider-$d; fi
  if [ -z "$dir" ] && [ -f "$toolchain/vendor.lock" ] && grep -q "^name = \"$d\"\$" "$toolchain/vendor.lock"; then
    sh "$toolchain/scripts/vendor.sh" fetch "$d" >&2 && dir=$toolchain/.vendor/$d
  fi
  if [ -n "$dir" ]; then
    dir=$(cd "$dir" && pwd -P) || die "$var: no directory $dir"
    EIDER_PKG_OVERRIDE="${EIDER_PKG_OVERRIDE:+$EIDER_PKG_OVERRIDE,}$d=$dir"
  fi
done
export EIDER_PKG_OVERRIDE
