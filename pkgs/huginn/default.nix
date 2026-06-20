{ buildGoModule
, cloud-hypervisor
, iproute2
, lib
, openssh
, virtiofsd
}:

buildGoModule {
  pname = "huginn";
  version = "0.1.0";

  src = ./.;
  vendorHash = null;
  subPackages = [ "cmd/huginn" ];

  ldflags = [
    "-s"
    "-w"
    "-X main.defaultCloudHypervisor=${lib.getExe cloud-hypervisor}"
    "-X main.defaultVirtiofsd=${lib.getExe virtiofsd}"
    "-X main.defaultIP=${iproute2}/bin/ip"
    "-X main.defaultSSHKeygen=${openssh}/bin/ssh-keygen"
  ];

  meta = {
    description = "Runtime control CLI for Huginn Cloud Hypervisor VMs";
    mainProgram = "huginn";
  };
}
