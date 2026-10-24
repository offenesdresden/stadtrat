{ pkgs ? import <nixpkgs> { } }:

pkgs.mkShell {
  buildInputs = with pkgs; [
    bundix
    (pkgs.callPackage ./bundle.nix {}).wrappedRuby

    pkgs.whisperx
    (ffmpeg.overrideAttrs (oldAttrs: {
        configureFlags = oldAttrs.configureFlags ++ [
          "--enable-libtesseract"
        ];
        buildInputs = oldAttrs.buildInputs ++ [
          pkgs.tesseract
        ];
      }))

    # keep this line if you use bash
    bashInteractive
  ];
}
