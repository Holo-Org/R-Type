#!/usr/bin/env bash
# Cross-builds r-type_server.exe and r-type_client.exe for 64-bit Windows from
# macOS, with nixpkgs' MinGW-w64 GCC, inside an ephemeral `nix shell`. The
# .exe files land in <target dir>/x86_64-pc-windows-gnu/release/.
#
# usage: bash scripts/build-windows-exe.sh [more `cargo build` arguments]
#
# Three things need help outside a nix build:
# - the GCC wrapper does not know where mcfgthread (its thread runtime) lives;
# - Rust's standard library for windows-gnu links winpthreads statically
#   (-l:libpthread.a), which this GCC does not ship: nixpkgs has it apart;
# - bindgen, inside the raylib crate's build, parses raylib.h with the host's
#   libclang for the Windows target, and must be shown the MinGW headers.
set -euo pipefail
cd "$(dirname "$0")/.."

store_path() { nix build --no-link --print-out-paths "$1"; }
MCFGTHREAD=$(store_path nixpkgs#pkgsCross.mingwW64.windows.mcfgthreads.out)
MCFGTHREAD_DEV=$(store_path nixpkgs#pkgsCross.mingwW64.windows.mcfgthreads.dev)
WINPTHREADS=$(store_path nixpkgs#pkgsCross.mingwW64.windows.pthreads)
export MCFGTHREAD MCFGTHREAD_DEV WINPTHREADS

exec nix shell nixpkgs#rustup nixpkgs#cmake nixpkgs#pkgsCross.mingwW64.buildPackages.gcc --command bash -c '
    set -euo pipefail
    export NIX_CFLAGS_COMPILE_x86_64_w64_mingw32="-isystem $MCFGTHREAD_DEV/include"
    export NIX_LDFLAGS_x86_64_w64_mingw32="-L$MCFGTHREAD/lib -L$WINPTHREADS/lib"
    gcc_support=$(dirname "$(command -v x86_64-w64-mingw32-gcc)")/../nix-support
    mingw_include=$(grep -o -- "-idirafter [^ ]*mingw-w64[^ ]*/include" "$gcc_support/libc-cflags" | cut -d" " -f2)
    export BINDGEN_EXTRA_CLANG_ARGS_x86_64_pc_windows_gnu="-isystem $mingw_include"
    export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=x86_64-w64-mingw32-gcc
    rustup target add x86_64-pc-windows-gnu
    cargo build --release --target x86_64-pc-windows-gnu --workspace --bins "$@"
' build-windows-exe "$@"
