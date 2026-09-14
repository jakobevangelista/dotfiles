{ aws-vault, awscli2, kubectl, kubelogin-oidc, makeWrapper, symlinkJoin }:

symlinkJoin {
  name = "cloud-tools";
  paths = [ aws-vault awscli2 kubectl kubelogin-oidc ];
  nativeBuildInputs = [ makeWrapper ];

  # Keep authentication usable in SSH sessions without a desktop keyring.
  postBuild = ''
    wrapProgram "$out/bin/aws-vault" \
      --set-default AWS_VAULT_BACKEND file \
      --set-default AWS_VAULT_PROMPT terminal \
      --set-default AWS_VAULT_STDOUT true
  '';
}
