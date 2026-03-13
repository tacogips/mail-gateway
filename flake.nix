{

  description = "mailer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-24.11";
    nixpkgs-unstable.url = "github:NixOS/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      nixpkgs-unstable,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
        pkgs-unstable = import nixpkgs-unstable { inherit system; };

        devPackages = with pkgs; [
          # Bun runtime
          pkgs-unstable.bun

          # TypeScript tooling
          pkgs-unstable.typescript
          pkgs-unstable.typescript-language-server
          nodePackages.prettier

          # Development tools
          fd
          gnused
          gh
          go-task
        ];

      in
      {
        devShells.default = pkgs.mkShell {
          packages = devPackages;

          shellHook = ''
            echo "TypeScript development environment ready"
            echo "Bun version: $(bun --version)"
            echo "TypeScript version: $(tsc --version)"
            echo "Task version: $(task --version 2>/dev/null || echo 'not available')"
          '';
        };
      }
    );
}
