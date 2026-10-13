{
  runCommand,
  src,
  plugin,
  version,
  sha256,
  size,
}:
runCommand "scryer-plugin-${plugin}-${version}"
  {
    inherit src;
    meta = {
      description = "Pinned ${plugin} WASM plugin for Scryer";
      homepage = "https://github.com/scryer-media/scryer-plugins";
      platforms = [ "x86_64-linux" ];
    };
  }
  ''
    echo '${sha256}  ${src}' | sha256sum --check
    test "$(stat -c %s ${src})" = ${toString size}
    install -Dm444 ${src} "$out/share/scryer/plugins/${plugin}/plugin-v3.wasm.zst"
  ''
