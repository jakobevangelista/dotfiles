{ config, ... }:

{
  # Enable CUDA on Odin's Ampere GPUs. This selects NVIDIA's driver even on
  # a headless host; it does not enable an X server or desktop session.
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.graphics.enable = true;

  hardware.nvidia = {
    open = true;
    modesetting.enable = true;
    nvidiaSettings = false;
    package = config.boot.kernelPackages.nvidiaPackages.stable;
  };
}
