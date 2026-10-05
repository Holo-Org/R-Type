#!/usr/bin/env bash
# The build description of the Odin POC: Odin has no build system, so this
# script checks the toolchain against odin.lock and the layering (ADR 0001),
# then builds the Server, the Client and the fuzz test into out/ ($ODIN_OUT
# moves it).
#
#   bash scripts/build.sh [release|debug|size|unchecked]
#   bash scripts/build.sh test
#
# release, the default, optimises for speed and keeps Odin's bounds checks;
# unchecked drops them (-no-bounds-check); size optimises for size; debug
# adds debug information and does not optimise. test runs the unit tests.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${ODIN_OUT:-out}
CHECKS=(-vet -strict-style)

case ${1:-release} in
release)   MODE=(-o:speed) ;;
unchecked) MODE=(-o:speed -no-bounds-check) ;;
size)      MODE=(-o:size) ;;
debug)     MODE=(-debug) ;;
test)
	mkdir -p "$OUT"
	odin test engine/headless "${CHECKS[@]}" -out:"$OUT/headless_tests"
	odin test game "${CHECKS[@]}" -out:"$OUT/game_tests"
	exit
	;;
*)
	echo "usage: bash scripts/build.sh [release|debug|size|unchecked|test]" >&2
	exit 2
	;;
esac

# The Odin release and the raylib library must be the ones odin.lock records.
# `odin version` says dev-2026-09-nightly:a2fb372 for the release archives,
# which Odin's nightly job builds, dev-2026-09:a2fb372b7 for a build from a Git
# checkout, and dev-2026-09 for one from a source archive, which names no commit.
pinned=$(awk '$1 == "odin" { print $2 }' odin.lock)
commit=$(awk '$1 == "odin" { print $3 }' odin.lock)
installed=$(odin version | awk '{ print $3 }')
release=${installed%%:*}
built_from=${installed#"$release"}
built_from=${built_from#:}
if [ "${release%-nightly}" != "$pinned" ] || { [ -n "$built_from" ] && [ "${commit#"$built_from"}" = "$commit" ]; }; then
	echo "odin.lock pins Odin $pinned ($commit), but this odin is $installed" >&2
	exit 1
fi
case $(uname -s)/$(uname -m) in
Darwin/*) library=vendor/raylib/macos/libraylib.a ;;
Linux/aarch64) library=vendor/raylib/linux-arm64/libraylib.a ;;
Linux/*) library=vendor/raylib/linux/libraylib.a ;;
esac
recorded=$(awk -v library="$library" '$1 == library { print $2 }' odin.lock)
path=$(odin root)/$library
if [ ! -f "$path" ]; then
	echo "$path is missing: this Odin's vendor collection is not the one odin.lock records" >&2
	exit 1
fi
if command -v sha256sum > /dev/null; then
	found=$(sha256sum "$path" | awk '{ print $1 }')
else
	found=$(shasum -a 256 "$path" | awk '{ print $1 }')
fi
if [ "$found" != "$recorded" ]; then
	echo "$path is not the library odin.lock records (SHA-256 $found)" >&2
	exit 1
fi

# The fuzz test counts calls to the C library's allocation functions: the
# linker makes its counting_malloc and so on the program's malloc and so on.
ALIASES=()
for f in malloc calloc realloc posix_memalign aligned_alloc mmap; do
	case $(uname -s) in
	Darwin) ALIASES+=("-Wl,-alias,_counting_$f,_$f") ;;
	Linux) ALIASES+=("-Wl,--defsym=$f=counting_$f") ;;
	esac
done

mkdir -p "$OUT"
odin build scripts/check_layering "${CHECKS[@]}" -out:"$OUT/check_layering"
"$OUT/check_layering" .
odin build server "${MODE[@]}" "${CHECKS[@]}" -out:"$OUT/r-type_server"
odin build client "${MODE[@]}" "${CHECKS[@]}" -out:"$OUT/r-type_client"
odin build tests/fuzz "${MODE[@]}" "${CHECKS[@]}" -out:"$OUT/protocol_fuzz" -extra-linker-flags:"${ALIASES[*]}"
