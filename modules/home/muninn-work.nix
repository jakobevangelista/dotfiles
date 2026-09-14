{
  config,
  lib,
  pkgs,
  ...
}:

let
  homeDir = config.home.homeDirectory;
  accounts = {
    SystemAdministrator-836356947314 = "836356947314";
    prod = "836356947314";
    stage = "909933634258";
    staging = "909933634258";
    sandbox = "243373301620";
    operations = "339712770658";
  };
in
{
  home.packages = [
    pkgs.google-cloud-sdk
    (pkgs.callPackage ../../pkgs/datadog-pup { })
    (pkgs.callPackage ../../pkgs/pscale { })
    (pkgs.callPackage ../../pkgs/work { })
  ];

  home.sessionVariables = {
    DD_TOKEN_STORAGE = "file";
    DD_SITE = "datadoghq.com";
    CLOUDSDK_CORE_PROJECT = "peerless-truck-309218";
    # Preserve the selected context in the imported configuration. Dedicated
    # EKS files are optional; both staging profile names remain usable.
    KUBECONFIG = "${homeDir}/.kube/config:${homeDir}/.kube/work-prod:${homeDir}/.kube/work-stage:${homeDir}/.kube/work-staging";
  };

  # Only non-secret profile metadata belongs in Nix. SSO cache, OAuth tokens,
  # and SSH private keys live in Muninn's private persistent home.
  home.file.".aws/config".text = ''
    [sso-session inngest]
    sso_start_url = https://inngest.awsapps.com/start
    sso_region = us-east-2
    sso_registration_scopes = sso:account:access
  ''
  + lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: account: ''
      [profile ${name}]
      sso_session = inngest
      sso_account_id = ${account}
      sso_role_name = SystemAdministrator
      region = us-east-2
      output = json
    '') accounts
  );

  programs.ssh = {
    enable = true;
    enableDefaultConfig = false;
    includes = [ "~/.ssh/config.local" ];
    matchBlocks = {
      "prod-bastion pgbouncer-b pgbouncer-c" = {
        user = "jakob";
        identityFile = "~/.ssh/id_ed25519_work";
        identitiesOnly = true;
        forwardAgent = false;
        extraOptions = {
          StrictHostKeyChecking = "yes";
          UserKnownHostsFile = "~/.ssh/work-known_hosts";
          ConnectTimeout = "10";
          ConnectionAttempts = "1";
        };
      };
      prod-bastion.hostname = "bastion-aws-prod.tail2dd48.ts.net";
      pgbouncer-b = {
        hostname = "172.16.88.155";
        proxyJump = "prod-bastion";
      };
      pgbouncer-c = {
        hostname = "172.16.90.206";
        proxyJump = "prod-bastion";
      };
    };
  };

  # Public host keys verified during the 2026-09-18 investigation. Jakob
  # explicitly approved the PgBouncer fingerprints through the bastion.
  home.file.".ssh/work-known_hosts".text = ''
    bastion-aws-prod.tail2dd48.ts.net ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIM1dBMV17W7OfptdV9/J6QsMxDes7bBKmqPUM5z9KRy1
    172.16.88.155 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFPwe1UeW/rjeEGJwRrqr1vCdqdVNNe/IyX2W5ApfTLp
    172.16.90.206 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPFI+p8JVt3CGx94UBAlwgFaV6nGGxEySTED8lnlKjMH
  '';
}
