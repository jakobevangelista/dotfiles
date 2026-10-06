{
  # Toshiba DT01ACA200, serial 24GG2ADTS; its old Windows D: disk image is
  # archived on Unraid in school-windows-backup/odin-d-drive-2026-09-26.
  # The ext4 root directory belongs to jakob:users. The underlying mountpoint
  # stays root-owned so a missing HDD cannot redirect user writes onto the SSD.
  fileSystems."/mnt/storage" = {
    device = "/dev/disk/by-uuid/8e230847-2175-484a-8aff-1e265a17a813";
    fsType = "ext4";
    options = [
      "nofail"
      "x-systemd.device-timeout=10s"
      "nodev"
      "nosuid"
    ];
  };
}
