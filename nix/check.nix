{
  runCommand,
  coreutils,
  dejavu_fonts,
  vela,
}:
runCommand "vela-startup-check"
  {
    nativeBuildInputs = [ coreutils ];
  }
  ''
    # No development-shell library paths or host font setup may be required.
    unset LD_LIBRARY_PATH LD_PRELOAD VELA_DATA_DIR
    export XDG_DATA_HOME="$TMPDIR/user data"
    export SDL_VIDEODRIVER=dummy
    export SDL_AUDIODRIVER=dummy
    export SDL_RENDER_DRIVER=software
    export VELA_FONT_PATH=${dejavu_fonts}/share/fonts/truetype/DejaVuSans.ttf
    status=0
    timeout --kill-after=5s 5s ${vela}/bin/vela > startup.log 2>&1 || status=$?
    cat startup.log
    test "$status" = 124
    test -d "$XDG_DATA_HOME/vela"
    test -f ${vela}/share/applications/vela.desktop
    mkdir -p "$out"
    cp startup.log "$out/"
  ''
