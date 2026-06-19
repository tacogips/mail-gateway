{

  description = "mailer";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/release-24.11";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };

        devPackages = with pkgs; [
          # Swift tooling
          swift
          swiftpm
          sourcekit-lsp

          # Development tools
          coreutils
          curl
          fd
          git
          gnutar
          gzip
          gnused
          gh
          go-task
        ];

      in
      {
        devShells.default = pkgs.mkShell {
          packages = devPackages;

          shellHook = ''
            echo "Swift development environment ready"
            echo "Swift version: $(swift --version | head -n 1)"
            echo "Task version: $(task --version 2>/dev/null || echo 'not available')"
          '';
        };
      }
    );
}
