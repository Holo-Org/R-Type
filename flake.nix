{
  # An optional development shell, for those who use Nix: nothing in the
  # repository depends on it, and the README's way, the official Zig archive
  # and the distribution's packages, stays the supported one.
  #
  #     nix develop        # Zig 0.16, ZLS, mdBook and the Client's libraries
  #
  # On a Linux distribution other than NixOS, a Client built in this shell
  # cannot reach the host's GPU driver, so build it outside the shell there.
  # Why, and the rest of the design: the research note on the
  # research/flake-non-nixos branch.
  description = "R-Type: an optional development shell";

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
              pkgs.zls_0_16
              # The docs site: see book.toml.
              pkgs.mdbook
              pkgs.mdbook-mermaid
            ];

            # Zig ignores /usr as soon as NIX_CFLAGS_COMPILE exists, so on Linux
            # the shell has to bring everything the Client links. Zig turns every
            # -L of NIX_LDFLAGS into a RUNPATH entry, which is how GLFW's dlopen
            # calls find these libraries.
            buildInputs = pkgs.lib.optionals isLinux [
              pkgs.libx11 # raylib links X11, Xrandr, Xinerama, Xi and Xcursor,
              pkgs.libxrandr # whose headers pull in xorgproto, Xrender, Xext and
              pkgs.libxinerama # Xfixes through propagatedBuildInputs
              pkgs.libxi
              pkgs.libxcursor
              pkgs.libglvnd # -lGL; at run time, libGLX and libGL
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
