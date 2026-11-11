{
  lib,
  stdenv,
  runCommand,
  coreutils,
  dejavu_fonts,
  vela,
}:
runCommand "${vela.pname}-startup-check" { nativeBuildInputs = [ coreutils ]; } ''
  unset LD_LIBRARY_PATH LD_PRELOAD DYLD_LIBRARY_PATH DYLD_FALLBACK_LIBRARY_PATH VELA_DATA_DIR
  export TMPDIR="$(realpath "$TMPDIR")"
  export HOME="$TMPDIR/home directory"
  mkdir -p "$HOME"
  export XDG_DATA_HOME="$TMPDIR/user data"
  export SDL_VIDEODRIVER=dummy SDL_AUDIODRIVER=dummy SDL_RENDER_DRIVER=software
  export VELA_FONT_PATH=${dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf
  status=0
  timeout --kill-after=5s 5s ${vela}/bin/vela > startup.log 2>&1 || status=$?
  cat startup.log
  test "$status" = 124
  test -d "$XDG_DATA_HOME/vela"
  ${lib.optionalString stdenv.hostPlatform.isLinux ''
    test -f ${vela}/share/applications/vela.desktop
  ''}
  ${lib.optionalString stdenv.hostPlatform.isDarwin ''
    test -f ${vela}/Applications/Vela.app/Contents/Info.plist
    test -x ${vela}/Applications/Vela.app/Contents/MacOS/vela
    unset XDG_DATA_HOME
    status=0
    timeout --kill-after=5s 5s ${vela}/Applications/Vela.app/Contents/MacOS/vela > app-startup.log 2>&1 || status=$?
    cat app-startup.log
    test "$status" = 124
    test -d "$HOME/Library/Application Support/vela"
  ''}
  mkdir -p "$out"
  cp *.log "$out/"
''
