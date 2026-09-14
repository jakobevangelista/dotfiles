{
  bash,
  neovim,
  openssh,
  python3,
  tmux,
  writeShellApplication,
}:

writeShellApplication {
  name = "odin-sessions";
  runtimeInputs = [
    neovim
    openssh
    tmux
  ];
  text = ''
    exec ${python3}/bin/python3 -B ${./.}/rescue.py "$@"
  '';
  derivationArgs = {
    doCheck = true;
    nativeCheckInputs = [ bash tmux ];
    checkPhase = ''
      ${python3}/bin/python3 -B -m unittest discover -s ${./.} -p 'test_*.py'
    '';
  };
}
