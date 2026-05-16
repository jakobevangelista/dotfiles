{ lib, ... }:

{
  # Replace this with the generated hardware file from the target machine:
  #   sudo nixos-generate-config --show-hardware-config
  fileSystems."/" = lib.mkDefault {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };
}
