{
  description = "iube — a small Wayland application launcher built with dvui";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "riscv64-linux" ];
      forAllSystems = nixpkgs.lib.genAttrs systems;
      forAllPkgs = nixpkgs.lib.genAttrs systems
        (system: import nixpkgs { inherit system; });

      makeDerivation = pkgs: pkgs.stdenv.mkDerivation (finalAttrs: {
        pname = "iube";
        version = "0.1.0";
        src = ./.;

        nativeBuildInputs = [ pkgs.zig ];  # activates the zig hook

        buildInputs = with pkgs; [
          libGL libxi
          wayland wayland-protocols libdecor libxkbcommon
        ];

        zigBuildFlags = [ "--release=fast" ];
        zigCheckFlags = finalAttrs.zigBuildFlags;
      });
    in
    {
      packages = forAllSystems (system: {
        iube    = makeDerivation forAllPkgs.${system};
        default = self.packages.${system}.iube;
      });

      overlays.default = final: prev:
        nixpkgs.lib.genAttrs systems
          (system: { iube = makeDerivation forAllPkgs.${system}; });

      devShells = forAllSystems (system: {
      default = forAllPkgs.${system}.mkShell {
        packages = [ forAllPkgs.${system}.zig forAllPkgs.${system}.zls forAllPkgs.${system}.pkg-config ];
        buildInputs = with forAllPkgs.${system}; [
          libGL libxi
          wayland wayland-protocols libdecor libxkbcommon
        ];
        LD_LIBRARY_PATH = forAllPkgs.${system}.lib.makeLibraryPath (with forAllPkgs.${system}; [
          libGL libxi
          wayland wayland-protocols libdecor libxkbcommon
        ]);
      };
    });   

    };
}   
