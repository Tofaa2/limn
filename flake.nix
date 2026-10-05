{
  outputs = {self, ...}: {
    devShells.x86_64-linux.default = let
      flake = builtins.getFlake "github:Tofaa2/devshells";
      system = "x86_64-linux";
      pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
      base = flake.devShells.${system}.zig;
    in
      pkgs.mkShell {
        inputsFrom = [base];
        packages = with pkgs; [
          shaderc
          vulkan-volk
          vulkan-memory-allocator
          ktx-tools
          git-lfs
          libx11
          libxrandr
          libxcursor
          libxext
          libxi
          glfw
          gcc
          wayland
          wayland-protocols
          wayland-scanner
          libxkbcommon
          pkg-config
          llvm
          libdecor
          libclang
          vulkan-validation-layers
          vulkan-loader
          vulkan-headers
          mesa
          libGL
          shader-slang
          directx-shader-compiler
          cmake
          vulkan-tools-lunarg
        ];
        LD_LIBRARY_PATH = pkgs.lib.makeLibraryPath [
          pkgs.mesa
          pkgs.libGL
          pkgs.libclang
          pkgs.vulkan-loader
          pkgs.libxkbcommon
          pkgs.wayland
          pkgs.libx11
          pkgs.libxrandr
          pkgs.libxcursor
          pkgs.libxext
          pkgs.libxi
        ];
      };
  };
}
