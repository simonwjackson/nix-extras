let
  repo = "simonwjackson/nix-extras";
  metadataTag = "cache";
  downloadBase = "https://github.com/${repo}/releases/download/";
in
{
  inherit repo metadataTag downloadBase;
  url = "${downloadBase}${metadataTag}/";
  publicKeys = [ "nix-extras-ci-1:+Vcq7i6dPWOsOZjQwOduCEZOZZJznS/XfOcNUhFmg3Q=" ];
  upstreams = [ "https://cache.nixos.org/" ];
  upstreamPublicKeys = [ "cache.nixos.org-1:6NCHdD59X431o0gWypbMrAURkbJ16ZPMQFGspcDShjY=" ];
}
