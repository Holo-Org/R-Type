# The optional flake on a Linux distribution other than NixOS

Last verified: 2026-10-16. Answers [ticket #9](https://github.com/Holo-Org/R-Type/issues/9).

The repository will ship an optional `flake.nix` whose dev shell provides Zig 0.16.0 and ZLS 0.16.0. Nix is never required: teammates on Linux install the official Zig archive and their distribution's X11 development packages, and CI uses `mlugg/setup-zig`. This note asks what happens when someone on a non-NixOS distribution builds and runs the Client from that dev shell instead.

Every fact is tagged with how I established it. I worked on macOS (aarch64) and had no Linux machine, so **nothing below was executed on Linux**.

- **[read]**: read in source or documentation, pinned to a tag or commit.
- **[run]**: done on this Mac. I cross-compiled raylib 6.0's C sources and small test programs to `x86_64-linux-gnu` with the Zig from nixpkgs, and inspected the objects and executables with `llvm-nm` and `readelf`. Linux libraries came from the nixpkgs binary cache and were never executed.
- **[inference]**: my reasoning from the above. Please treat as unverified.

## Short answer

- **Does the Client built in the dev shell find the host's GPU driver?** No, not by itself. Zig from nixpkgs links the executable against Nix's glibc and Nix's libglvnd. Both look for the GPU vendor libraries in `/run/opengl-driver/lib`, which only NixOS provides, and neither ever looks in `/usr/lib`. On a non-NixOS distribution the window cannot get an OpenGL context unless something like nixGL puts a driver where the executable can find it. [read] [inference]
- **Should the shell provide the X11 and OpenGL development libraries?** Yes. In a Nix dev shell Zig no longer looks at `/usr/include` and `/usr/lib` at all, so there is nothing to "leave to the distribution". The shell has to bring every header and library the Client links. [read] [run, on macOS, for the mechanism]
- **Does the executable run outside the shell?** On the same machine, yes: its interpreter and library paths are absolute `/nix/store` paths. On a teammate's machine without Nix, no. [read] [inference]
- **Recommendation:** put the five X11 libraries, libglvnd and the audio libraries in the Linux dev shell, leave nixGL out of the flake, and document that on non-NixOS Linux the supported way to build and run the Client is still the official Zig archive plus distribution packages. A draft is at the end.
- **Side finding for the macOS teammate:** in a `mkShell` dev shell Zig cannot find the macOS frameworks, so the Client would not link. The draft shell works around it with one line. [run]

## Versions checked

| Item | Version | Source |
| --- | --- | --- |
| Zig | 0.16.0 (nixpkgs `zig_0_16`) | [source tag](https://codeberg.org/ziglang/zig/src/tag/0.16.0) |
| ZLS | 0.16.0 (nixpkgs `zls`) | nixpkgs, below |
| nixpkgs | `nixpkgs-unstable` at [`319e4ce`](https://github.com/NixOS/nixpkgs/commit/319e4cebef10cbb636c6ea392137b52ad105336a), locked 2026-10-14; glibc 2.44, libglvnd 1.7.0, Mesa 26.2.4 | `nix eval` on that revision |
| raylib | 6.0, tag commit `dbc56a8` | [raysan5/raylib](https://github.com/raysan5/raylib/tree/6.0) |
| GLFW bundled in raylib | 3.4.0 | [CMakeLists.txt](https://github.com/raysan5/raylib/blob/6.0/src/external/glfw/CMakeLists.txt) |
| raylib-zig | `8758f4c`, the commit pinned in `build.zig.zon` | [raylib-zig](https://github.com/raylib-zig/raylib-zig/tree/8758f4cd3a5ae0df6941c4715257223d34c5ad3e) |
| libglvnd | 1.7.0 | [v1.7.0](https://gitlab.freedesktop.org/glvnd/libglvnd/-/tree/v1.7.0) |
| nixGL | `b610529` (2025-11-02, the latest commit on the default branch) | [nix-community/nixGL](https://github.com/nix-community/nixGL/tree/b6105297e6f0cd041670c3e8628394d4ee247ed5) |
| nix-gl-host | `5269b23` (2024-11-21, the latest commit on the default branch) | [numtide/nix-gl-host](https://github.com/numtide/nix-gl-host/tree/5269b233f83880a0b433eafe026f0bc0d8f1a4a9) |
| Home Manager | `6407259` (2026-10-15) | [nix-community/home-manager](https://github.com/nix-community/home-manager/tree/640725978b99076e18e069f6e7d2959124584f8f) |

## 1. How raylib 6.0 reaches the windowing system and OpenGL on Linux

### What is built

- **Platform backend: GLFW.** raylib's `build.zig` defaults to `platform = .glfw` ([build.zig L515](https://github.com/raysan5/raylib/blob/6.0/build.zig#L515)) and compiles the GLFW 3.4 sources it carries (`rglfw.c`). [read]
- **Display backend: X11 only.** The default is `linux_display_backend = .X11` ([L517](https://github.com/raysan5/raylib/blob/6.0/build.zig#L517)), and raylib-zig does not override it: its `Options` is raylib's ([raylib-zig build.zig L8](https://github.com/raylib-zig/raylib-zig/blob/8758f4cd3a5ae0df6941c4715257223d34c5ad3e/build.zig#L8)). On a Wayland desktop the Client therefore runs through XWayland. Wayland needs `-Dlinux_display_backend=Wayland` or `Both`, plus `wayland-scanner` at build time ([L94-L102](https://github.com/raysan5/raylib/blob/6.0/build.zig#L94-L102), [L245-L251](https://github.com/raysan5/raylib/blob/6.0/build.zig#L245-L251)); raylib's own wiki calls GLFW's Wayland support "experimental and incomplete" ([raylib wiki](https://github.com/raysan5/raylib/wiki/Working-on-GNU-Linux)). [read]
- **Libraries named at link time:** `GL`, `X11`, `Xrandr`, `Xinerama`, `Xi`, `Xcursor` ([build.zig L104-L115, L238-L243](https://github.com/raysan5/raylib/blob/6.0/build.zig#L104-L115)). No audio library is linked. [read]
- **Headers needed at compile time:** GLFW's X11 backend includes `Xlib.h`, `Xcursor.h`, `Xrandr.h`, `XKBlib.h`, `Xinerama.h`, `XInput2.h` and `extensions/shape.h` ([x11_platform.h L32-L51](https://github.com/raysan5/raylib/blob/6.0/src/external/glfw/src/x11_platform.h#L32-L51)). No OpenGL header is needed: raylib uses its own `glad.h`, and the GLFW part defines `GLFW_INCLUDE_NONE` ([rcore_desktop_glfw.c L49](https://github.com/raysan5/raylib/blob/6.0/src/platforms/rcore_desktop_glfw.c#L49)). [read]
- **Compiling `rglfw.c` and `rcore.c` with only the development outputs of libX11, Xrandr, Xinerama, Xi and Xcursor fails.** The error chain is: `X11/X.h` (xorgproto), then `extensions/Xrender.h` (called by `Xrandr.h`), then `extensions/Xge.h` (libXext, called by `XInput2.h`), then `extensions/Xfixes.h` (libXfixes, called by `XInput2.h`). With those four added it compiles. In nixpkgs the development outputs of the five libraries propagate those four, so listing the five is enough there. [run]

### What is loaded at run time

GLFW opens most of its dependencies with `dlopen`, so they are not on the executable's list of needed libraries.

| Library (soname) | Opened by | Source |
| --- | --- | --- |
| `libX11.so.6` | GLFW, at start-up | [x11_init.c L1264](https://github.com/raysan5/raylib/blob/6.0/src/external/glfw/src/x11_init.c#L1264) |
| `libXrandr.so.2`, `libXi.so.6`, `libXcursor.so.1`, `libXinerama.so.1`, `libXrender.so.1`, `libXext.so.6`, `libX11-xcb.so.1`, `libXxf86vm.so.1` | GLFW, each on demand | [x11_init.c L611-L883](https://github.com/raysan5/raylib/blob/6.0/src/external/glfw/src/x11_init.c#L611-L883) |
| `libGLX.so.0`, then `libGL.so.1`, then `libGL.so` | GLFW's GLX context, the default on X11 | [glx_context.c L265-L272](https://github.com/raysan5/raylib/blob/6.0/src/external/glfw/src/glx_context.c#L265-L272) |
| `libEGL.so.1` | GLFW, only when an EGL context is requested | [egl_context.c L374-L380](https://github.com/raysan5/raylib/blob/6.0/src/external/glfw/src/egl_context.c#L374-L380) |
| `libasound.so.2`, `libpulse.so.0` | miniaudio, inside raylib's audio module | [miniaudio.h L30008](https://github.com/raysan5/raylib/blob/6.0/src/external/miniaudio.h#L30008), [L32550](https://github.com/raysan5/raylib/blob/6.0/src/external/miniaudio.h#L32550) |

The OpenGL functions themselves are loaded through `glfwGetProcAddress` ([rcore_desktop_glfw.c L1801](https://github.com/raysan5/raylib/blob/6.0/src/platforms/rcore_desktop_glfw.c#L1801)). [read]

I compiled raylib 6.0's `rcore`, `rglfw`, `rtextures`, `rshapes`, `rtext`, `rmodels` and `raudio` for `x86_64-linux-gnu` with the flags `build.zig` sets (X11 backend, OpenGL 3.3), linked them with a four-line `main.c` and the same `-l` flags, and read the result: [run]

- No object references a `gl*`, `glX*` or `egl*` symbol. The only Xlib symbols come from raylib's clipboard-image code in `rcore.c` (`XOpenDisplay`, `XNextEvent`, and seven more), so the executable's only graphics entry in its needed-library list is **`libX11.so.6`**. This is a link of my own, not `zig build` of the real Client; I did not run raylib-zig's `build.zig`, because that means executing downloaded build scripts.
- Zig passes `--as-needed` to the linker for system libraries unless asked otherwise ([Lld.zig L1144](https://codeberg.org/ziglang/zig/src/tag/0.16.0/src/link/Lld.zig#L1144)), so `-lGL`, `-lXrandr`, `-lXinerama`, `-lXi` and `-lXcursor` must be found by the linker but do not end up in the executable. I checked the mechanism with a stub library: referenced, it appears in the needed list; unreferenced, it does not. [run]

**Consequence:** at build time `libGL.so` and the four other `.so` files must exist (development packages); at run time `libGLX.so.0` or `libGL.so.1`, the X libraries and the audio libraries must be found by `dlopen` from inside the Client's own code. That matters in section 3.

## 2. How Zig from nixpkgs finds system libraries and headers

- **The nixpkgs `zig` package is the plain compiler.** It has no cc-wrapper. Its setup hook only defines build phases for packaging ([setup-hook.sh](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/development/compilers/zig/setup-hook.sh); [manual](https://nixos.org/manual/nixpkgs/unstable/#zig)). The cc-wrapper variant (`zig.cc`) exists but a dev shell does not use it. [read]
- **Zig reads Nix's variables itself.** On a native target, `NativePaths.detect` parses `NIX_CFLAGS_COMPILE` (`-isystem`, `-idirafter`), `NIX_LDFLAGS` and `NIX_CFLAGS_LINK` (`-L`, `-rpath`) ([NativePaths.zig L26-L109](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/zig/system/NativePaths.zig#L26-L109)). Every `-L` becomes both a library directory and an `rpath` entry. [read]
- **If any of those variables exists, Zig stops there.** `if (is_nix) return self` comes before the list of `/usr/include`, `/usr/lib/<triple>` and friends ([L111](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/zig/system/NativePaths.zig#L111)). So Zig in a Nix shell cannot see the host's `/usr/include` or `/usr/lib`. [read]
- **Every stdenv-based shell has `NIX_CFLAGS_COMPILE`.** stdenv's `reproducible-builds.sh` always appends `-frandom-seed=…` ([stdenv/generic/default.nix L30](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/stdenv/generic/default.nix#L30), [hook](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/build-support/setup-hooks/reproducible-builds.sh)). On top of that, cc-wrapper and bintools-wrapper hooks add `-isystem <dir>/include` and `-L<dir>/lib` for each `buildInputs` entry ([cc-wrapper hook L74](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/build-support/cc-wrapper/setup-hook.sh#L74), [bintools hook L27](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/build-support/bintools-wrapper/setup-hook.sh#L27)). [read]
  - [run] On macOS, `nix-shell` with `mkShell` and with `mkShellNoCC` both export `NIX_CFLAGS_COMPILE`, and Zig then fails to link a trivial program with `-framework Foundation` (`unable to find framework 'Foundation'. searched paths: none`). `nix shell nixpkgs#zig_0_16`, which has no stdenv, links it; so does `unset NIX_CFLAGS_COMPILE NIX_LDFLAGS` inside the dev shell. The earlier Zig POC report used `nix shell`, which is why it did not hit this.
  - [inference] The same code path applies on Linux, so a shell holding only `zig` and `zls` cannot see the host's X11 headers either. The `/usr` fallback is reachable only without stdenv (`nix shell`) or after unsetting the variables.
- **Builds with an explicit `-Dtarget=` skip all of this.** Native path detection needs `is_native_os and is_native_abi` ([main.zig L4089](https://codeberg.org/ziglang/zig/src/tag/0.16.0/src/main.zig#L4089)). The Windows cross-build is unaffected, and so would be a Linux build for an explicit Linux target (section 4). [read]
- **Zig may ask `pkg-config` first.** `linkSystemLibrary` defaults to `use_pkg_config = .yes`: it runs `pkg-config <name> --cflags --libs` and falls back to `-lname` only if that fails ([Compile.zig L1127-L1160](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/Build/Step/Compile.zig#L1127-L1160)). `nix develop` keeps the host's `PATH`, so a host `pkg-config` could answer with host paths. I have not tested what happens then. [read] [inference]

### Which glibc the executable gets

nixpkgs patches Zig's native-target detection. Upstream inspects `/usr/bin/env` as an ELF file to learn the system's dynamic linker and glibc version ([system.zig L958](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/zig/system.zig#L958)); nixpkgs replaces that path with its own coreutils' `env` ([generic.nix L86-L90](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/development/compilers/zig/generic.nix#L86-L90)). I confirmed the substitution in the cached `x86_64-linux` `zig_0_16`: the path is in its binary and in its bundled `lib/zig/std/zig/system.zig`. [run]

**Inference:** the executables Zig builds natively in a Nix shell therefore get Nix's glibc loader as their interpreter (`PT_INTERP`, read from `env` at [system.zig L614-L636](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/zig/system.zig#L614-L636)), and a `RUNPATH` made of the shell's `-L` directories ([main.zig L4080-L4101](https://codeberg.org/ziglang/zig/src/tag/0.16.0/src/main.zig#L4080-L4101)). Zig 0.16.0 does emit `DT_RUNPATH`, not `DT_RPATH`, for `-rpath` on Linux targets. [run] Nix's glibc is patched to ignore `/etc/ld.so.cache` ([glibc common.nix L87](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/development/libraries/glibc/common.nix#L87)), so the executable finds libraries only through `RUNPATH`, `LD_LIBRARY_PATH` and Nix's own glibc directory.

## 3. Does the Client find the host's GPU driver at run time?

### The search order

`dlopen` from the executable's code uses, in order: `LD_LIBRARY_PATH`, the executable's `DT_RUNPATH`, `/etc/ld.so.cache`, then `/lib` and `/usr/lib` ([dlopen(3)](https://man7.org/linux/man-pages/man3/dlopen.3.html), [ld.so(8)](https://man7.org/linux/man-pages/man8/ld.so.8.html)). A `RUNPATH` applies only to the object that holds it and not to the libraries it loads. Because GLFW is compiled into the Client, its `dlopen` calls use the Client's `RUNPATH`. [read]

### The chain on NixOS and why it breaks elsewhere

1. The Client's GLFW opens `libGLX.so.0` from its `RUNPATH`, which holds Nix's libglvnd when libglvnd is in the shell. [inference]
2. libglvnd's GLX then `dlopen`s the vendor library `libGLX_<vendor>.so.0`, named after the vendor the X server reports ([libglxmapping.c L295](https://gitlab.freedesktop.org/glvnd/libglvnd/-/blob/v1.7.0/src/GLX/libglxmapping.c#L295), [L428](https://gitlab.freedesktop.org/glvnd/libglvnd/-/blob/v1.7.0/src/GLX/libglxmapping.c#L428)). [read]
3. nixpkgs' libglvnd gives `libGLX.so` a `RUNPATH` starting with `/run/opengl-driver/lib` ([package.nix L84-L88](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/by-name/li/libglvnd/package.nix#L84-L88), [addDriverRunpath](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/by-name/ad/addDriverRunpath/setup-hook.sh)). I confirmed it in the cached `x86_64-linux` build: `libGLX.so.0` has `RUNPATH [/run/opengl-driver/lib:/nix/store/…-libx11…]`. [run]
4. NixOS creates `/run/opengl-driver` when `hardware.graphics` is enabled ([graphics.nix L134](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/nixos/modules/hardware/graphics.nix#L134)), and fills it with the Mesa or NVIDIA libraries matching the installed kernel. [read]
5. On another distribution `/run/opengl-driver` does not exist. libGLX's remaining search places are `LD_LIBRARY_PATH`, the (ignored) cache and Nix glibc's own directory, so `libGLX_mesa.so.0` or `libGLX_nvidia.so.0` is not found, and GLFW cannot create a context. [inference]
6. EGL is a different story but does not matter here: nixpkgs' libglvnd reads vendor files from FHS directories too (`/usr/share/glvnd/egl_vendor.d`, [package.nix L60-L62](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/by-name/li/libglvnd/package.nix#L60-L62)), but GLFW's X11 path uses GLX. [read]

nixGL's README opens with the failure this produces: "libGL error: unable to load driver …" ([README](https://github.com/nix-community/nixGL/blob/b6105297e6f0cd041670c3e8628394d4ee247ed5/README.md)). nix-gl-host's lists "couldn't find RGB GLX visual or fbconfig" ([README](https://github.com/numtide/nix-gl-host/blob/5269b233f83880a0b433eafe026f0bc0d8f1a4a9/README.md)). The nixpkgs manual itself sends people to nixGL or nix-gl-host for running Nix-built GPU programs outside NixOS ([CUDA section L327, L355](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/doc/languages-frameworks/cuda.section.md#L327)). [read]

Even without Nix's libglvnd on the `RUNPATH`, the Client would not reach the host's `libGL.so.1`: Nix's loader skips the host's `ld.so.cache`. Pointing `LD_LIBRARY_PATH` at `/usr/lib/<triple>` mixes host libraries into a Nix-glibc process; nix-gl-host's design notes call that risky and copy only the top-level driver libraries, patching their `RUNPATH` ([INTERNALS.md](https://github.com/numtide/nix-gl-host/blob/5269b233f83880a0b433eafe026f0bc0d8f1a4a9/INTERNALS.md)). [inference]

### What fixes it

| Tool | What it does | Fit here |
| --- | --- | --- |
| [nixGL](https://github.com/nix-community/nixGL/blob/b6105297e6f0cd041670c3e8628394d4ee247ed5/nixGL.nix) | Wraps the program with `LD_LIBRARY_PATH`, `LIBGL_DRIVERS_PATH` and `__EGL_VENDOR_LIBRARY_FILENAMES` pointing at **Nix's own** Mesa, or, for NVIDIA, at a userspace driver downloaded from nvidia.com to match the host's kernel module. The README calls it "badly tested" and says it must use the same nixpkgs as the program, or glibc versions clash. | Works for Mesa GPUs (Intel, AMD, nouveau) with `nixGLIntel`, which needs no impure evaluation. NVIDIA needs `--impure` (it reads `/proc/driver/nvidia/version`) and a network download. |
| [nix-gl-host](https://github.com/numtide/nix-gl-host/blob/5269b233f83880a0b433eafe026f0bc0d8f1a4a9/README.md) | Copies the **host's** driver libraries, patches their `RUNPATH`, and injects them through `LD_LIBRARY_PATH`. Status "alpha"; the support matrix marks proprietary NVIDIA as supported and Mesa, nouveau and AMD as not supported. Last commit 2024-11-21. | Only helps NVIDIA machines. |
| [Home Manager `targets.genericLinux.gpu`](https://github.com/nix-community/home-manager/blob/640725978b99076e18e069f6e7d2959124584f8f/modules/targets/generic-linux/gpu/default.nix) | Builds a driver environment and, after a one-time `sudo` setup, makes `/run/opengl-driver` exist on the non-NixOS host, so nixpkgs' `RUNPATH` just works. NVIDIA needs the exact driver version and a hash. | Needs Home Manager and root. Too heavy for this team. |
| Nothing | Native executable built with the official Zig and the distribution's packages. | The decided route. |

For NVIDIA, all three Nix-side tools need the userspace driver to match the host's kernel module version exactly: nixGL detects the version, Home Manager asks for it and says it "must match" ([option text](https://github.com/nix-community/home-manager/blob/640725978b99076e18e069f6e7d2959124584f8f/modules/targets/generic-linux/gpu/default.nix)). For Mesa, nixGL and Home Manager ship Nix's Mesa, whose support for a given GPU depends on the nixpkgs revision. Which GPUs the teammates have is unknown (see "Not established").

## 4. Does a binary built in the shell run outside it?

- **Same machine, outside the shell: yes.** The interpreter and every `RUNPATH` entry are absolute store paths, so no environment variable from the shell is needed at run time. The shell only matters while building. The store paths must still exist: `nix develop` does not root them, so a garbage collection can delete them. [inference]
- **Teammate's machine without Nix: no.** The kernel looks for `/nix/store/…-glibc-…/lib/ld-linux-x86-64.so.2` and does not find it; the shell reports "No such file or directory" for the executable. The same holds for the Server. [inference]
- **What it would take**, from cheapest to most work (none tried on Linux):
  1. Do not hand Nix-built executables around. Each person builds with the official Zig and distribution packages, as decided. CI does the same.
  2. Build against the host's glibc instead: an explicit `-Dtarget=x86_64-linux-gnu.<glibc>` makes Zig use the standard interpreter `/lib64/ld-linux-x86-64.so.2` and its own bundled glibc stubs. Native path detection is then off, so headers and libraries must come from `--search-prefix` (a merged prefix of the shell's X11 and libglvnd outputs) and the executable gets no `RUNPATH`. I linked raylib 6.0 this way by hand, with the shell's X11 and libglvnd outputs as plain `-L` directories, and got: interpreter `/lib64/ld-linux-x86-64.so.2`, no `RUNPATH`, needed libraries `libX11.so.6`, `libm`, `libc`, `libpthread` and `libdl`, and symbol versions up to `GLIBC_2.29` for an unversioned `x86_64-linux-gnu` target. [run] The host's loader would then supply `libX11`, `libGLX`, `libGL` and the vendor libraries from its own directories, so no nixGL would be needed. [inference] This is the same mechanism as the Windows cross-build, and the only option here that makes the shell's output usable on a non-NixOS machine. It needs a glibc floor chosen on purpose, a `--search-prefix` wrapper in the flake (not drafted), and a Linux test I could not do.
  3. Rewrite a Nix-built executable with `patchelf` (new interpreter, no `RUNPATH`). It was linked against Nix's newer glibc, so older hosts may lack symbol versions. Not recommended. [inference]

## 5. Recommendation

1. **Put the X11 and OpenGL libraries in the Linux dev shell.** The shell is cut off from `/usr` (section 2), so without them `zig build` fails on the first `#include <X11/Xlib.h>`. Use the five libraries `raylib-zig` links (`libx11`, `libxrandr`, `libxinerama`, `libxi`, `libxcursor`) and `libglvnd` (which `pkgs.libGL` is on Linux, [all-packages.nix L6107](https://github.com/NixOS/nixpkgs/blob/319e4cebef10cbb636c6ea392137b52ad105336a/pkgs/top-level/all-packages.nix#L6107)). Their development outputs bring xorgproto, Xrender, Xext and Xfixes. Also add `alsa-lib` and `libpulseaudio`: they are not needed to build, but miniaudio `dlopen`s them and the Client's `RUNPATH` is the only place they can come from.
2. **Do not put nixGL in the flake.** It must follow the shell's nixpkgs, the NVIDIA variants are impure, and nobody on the team needs it to build or grade the project. Document it as an escape hatch (below).
3. **No environment variables on Linux.** `LD_LIBRARY_PATH` and `LIBGL_*` are nixGL's job.
4. **On macOS, unset `NIX_CFLAGS_COMPILE` and `NIX_LDFLAGS`** in `shellHook`, or Zig cannot find the frameworks. [run]
5. **Say in the docs what the shell is for.** Suggested wording: "The optional Nix shell gives you Zig 0.16.0 and ZLS 0.16.0 and, on Linux, everything the Client links. On NixOS and on macOS the Client built in it runs. On any other Linux distribution it does not find your GPU driver unless you wrap it with nixGL; build and run the Client with the official Zig archive and your distribution's packages instead (see Setup)."
6. **Do not add `x86_64-darwin`.** nixpkgs 26.11 refuses to evaluate it (`nix eval` on `319e4ce` prints a pointer to the release notes). [run]

For someone on non-NixOS who insists on running the Nix-built Client, the commands from nixGL's README are (untested here):

```sh
# Mesa GPUs (Intel, AMD, nouveau); pure
nix run github:nix-community/nixGL#nixGLIntel -- ./zig-out/bin/<client>
# NVIDIA; impure, and the nixpkgs must be the flake.lock's
nix run --impure --override-input nixpkgs github:NixOS/nixpkgs/<rev from flake.lock> github:nix-community/nixGL -- ./zig-out/bin/<client>
```

### Draft `flake.nix`

I evaluated this on all three systems (`nix eval .#devShells.<system>.default.drvPath`), and entered it with `nix develop` on aarch64-darwin: `zig version` and `zls --version` both print 0.16.0, and a program linking `-framework Foundation` builds. The Linux part was evaluated, never run.

```nix
{
  description = "R-Type: optional development shell (nothing in the repository depends on it)";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixpkgs-unstable";

  outputs =
    { nixpkgs, ... }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
        "aarch64-darwin"
      ];
      forEachSystem = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      devShells = forEachSystem (
        pkgs:
        let
          inherit (pkgs.stdenv.hostPlatform) isLinux isDarwin;
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.zig_0_16
              pkgs.zls
            ];

            # Zig ignores /usr as soon as NIX_CFLAGS_COMPILE exists, so on Linux the shell
            # has to bring everything the Client links. Zig turns every -L of NIX_LDFLAGS
            # into a RUNPATH entry, which is how GLFW's dlopen calls find these libraries.
            buildInputs = pkgs.lib.optionals isLinux [
              pkgs.libx11 # raylib-zig links X11, Xrandr, Xinerama, Xi and Xcursor,
              pkgs.libxrandr # and their headers pull in xorgproto, Xrender, Xext and
              pkgs.libxinerama # Xfixes through propagatedBuildInputs
              pkgs.libxi
              pkgs.libxcursor
              pkgs.libglvnd # `-lGL`; at run time, libGLX and libGL
              pkgs.alsa-lib # miniaudio dlopens libasound and libpulse
              pkgs.libpulseaudio
            ];

            # On macOS, Zig only looks for the SDK when no NIX_* variable exists.
            shellHook = pkgs.lib.optionalString isDarwin ''
              unset NIX_CFLAGS_COMPILE NIX_LDFLAGS
            '';
          };
        }
      );
    };
}
```

On older nixpkgs the libraries live under `xorg.libX11`, `xorg.libXrandr` and so on; the short names above exist at `319e4ce`.

## Not established

- **Whether the Client opens a window in this shell on any Linux machine.** Each link of the chain is read or inspected, but the whole was never run. In particular I did not run `zig build` for the real Client (it executes downloaded build scripts), so the combination of Zig's native path detection with the real Linux `NIX_LDFLAGS` is unverified. The parser also stops at the first unrecognised word in `NIX_LDFLAGS` ([L76](https://codeberg.org/ziglang/zig/src/tag/0.16.0/lib/std/zig/system/NativePaths.zig#L76)).
- **The macOS side with the real Client.** The `unset` line was tested with a plain program linking `-framework Foundation`, not with the Client and raylib's frameworks.
- **Which distributions, which GPUs and which session type (X11 or Wayland) the two teammates run.** That decides whether nixGL (Mesa) or nix-gl-host (NVIDIA only) would even apply, and whether XWayland is present.
- **What a host `pkg-config` on `PATH` does** inside `nix develop` (section 2).
- **Audio.** I only established which libraries are `dlopen`ed. Whether Nix's alsa-lib or libpulse reaches the host's sound server on non-NixOS is untested.
- **glibc 2.44 in `nixpkgs-unstable`.** It is probably newer than the newest glibc Zig 0.16.0 has stubs for; the source says it warns and uses the latest known version ([glibc.zig L736-L752](https://codeberg.org/ziglang/zig/src/tag/0.16.0/src/libs/glibc.zig#L736-L752)), but I did not run it.
- **Closure size** of the Linux shell.
- **nixGL's current state against nixpkgs-unstable of 2026-10.** Its last commit is from 2025-11-02 and I did not build it.

## How I checked

Sources were cloned or downloaded to a scratch directory outside the repository and never executed. Experiments, all on macOS:

- `zig cc -target x86_64-linux-gnu` on raylib 6.0's C sources, with Linux headers from `legacyPackages.x86_64-linux` dev outputs fetched with `nix build --max-jobs 0`; `llvm-nm -u` on the objects.
- A hand link of those objects with `-L` and `-lGL -lX11 -lXrandr -lXinerama -lXi -lXcursor`; `readelf -d` and `readelf -p .interp` on the result.
- `zig build-exe` of two tiny programs against a stub `libfoo.so.1` to see `--as-needed` and `-rpath` behaviour.
- `readelf -d` and `strings` on the cached `x86_64-linux` `libglvnd` and `zig_0_16` outputs.
- `nix-shell` and `nix develop` on aarch64-darwin with `mkShell`, `mkShellNoCC` and the draft flake, with `zig build-exe … -framework Foundation`.
