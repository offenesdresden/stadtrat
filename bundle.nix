{ ruby, bundlerEnv }:

bundlerEnv {
  name = "scrapers";

  inherit ruby;
  # expects Gemfile, Gemfile.lock and gemset.nix in the same directory
  # > nix-shell
  # > bundle lock --update
  # > bundix
  gemdir = ./.;
}
