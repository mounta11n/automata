{ pkgs ? import <nixpkgs> {} }:

let
  mix2nix = pkgs.fetchFromGitHub {
    owner = "shlevy";
    repo = "mix2nix";
    rev = "master";
    sha256 = "sha256:0kvr1d3j7mv3mkb05sy3w0r44nxfs7cx5a4q0vly7l1k3w8v5c0v";
  };

  elixirDeps = pkgs.callPackage ./deps.nix {};

  automata = pkgs.elixir_1_17.overrideDerivation pkgs.elixir_1_17.overrideAttrs (old: {
    buildInputs = old.buildInputs ++ [ pkgs.mix ];
  });
in

pkgs.dockerTools.buildLayeredImage {
  name = "automata";
  tag = "latest";
  created = "now";
  
  contents = [
    pkgs.elixir_1_17
    pkgs.mix
    pkgs.erlang
    pkgs.bashInteractive
  ];
  
  extraCommands = ''
    mkdir -p /app
    chmod 755 /app
  '';
  
  config = {
    Cmd = [ "/usr/bin/mix" "phx.server" ];
    Expose = [ 4000 ];
    Env = [
      "MIX_ENV=prod"
      "PHX_HOST=localhost"
      "PORT=4000"
    ];
  };
}
