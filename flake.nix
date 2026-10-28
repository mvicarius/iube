{
  description = "iube — a small Wayland application launcher built with dvui";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      # SDL3 (built by dvui) uses these backends; the dev shell also supplies
      # the runtime libraries for the resulting executable.
      libs = with pkgs; [
        wayland
        wayland-protocols
        libdecor
        libxkbcommon

        libx11
        libxcursor
        libxext
        libxfixes
        libxi
        libxinerama
        libxrandr
        libxrender

        libGL
        libGLX
        mesa
        vulkan-loader

        alsa-lib
        libpulseaudio
        libusb1
        udev
        dbus

        freetype
        harfbuzz
        fontconfig
        libpng
      ];
    in
    {
      devShells.${system}.default = pkgs.mkShell {
        packages = [ pkgs.zig pkgs.zls pkgs.pkg-config ];
        buildInputs = libs;
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath libs;
      };
    };
}
