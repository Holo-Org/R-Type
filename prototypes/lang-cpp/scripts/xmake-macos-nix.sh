#!/usr/bin/env bash
# macOS only: runs xmake with nixpkgs' LLVM 22 (clang and libc++, which ships
# the sources of the `std` module), inside an ephemeral `nix shell`. Apple
# clang cannot `import std`. Linux and Windows do not need this script.
#
# usage: bash scripts/xmake-macos-nix.sh <xmake arguments>
#   bash scripts/xmake-macos-nix.sh f -y --toolchain=clang
#   bash scripts/xmake-macos-nix.sh
#   bash scripts/xmake-macos-nix.sh run r-type_server
set -euo pipefail
cd "$(dirname "$0")/.."

# The nixpkgs clang wrapper adds the SDK and libc++ include paths when it
# compiles, but xmake also runs clang-scan-deps (from the unwrapped clang),
# which only sees them through SDKROOT and CPLUS_INCLUDE_PATH. The driver finds
# libc++.modules.json, which sits in libc++'s own store path, through
# COMPILER_PATH.
exec nix shell nixpkgs#xmake nixpkgs#llvmPackages_22.libcxxClang nixpkgs#llvmPackages_22.clang-unwrapped \
    --command bash -c '
        set -euo pipefail
        support=$(dirname "$(command -v clang++)")/../nix-support
        libcxx_include=$(grep -o -- "-cxx-isystem [^ ]*" "$support/libcxx-cxxflags" | cut -d" " -f2)
        libcxx=$(tr -d " \n" < "${libcxx_include%/include/c++/v1}/nix-support/propagated-build-inputs")
        developer_dir=$(sed -n "s/.*DEVELOPER_DIR_[a-z0-9_]*:-\([^}]*\)}.*/\1/p" "$support/darwin-sdk-setup.bash")
        export COMPILER_PATH="$libcxx/lib"
        export SDKROOT="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
        export CPLUS_INCLUDE_PATH="$libcxx_include"
        exec xmake "$@"
    ' xmake "$@"
