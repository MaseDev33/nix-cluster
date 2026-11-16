{ ... }:
{
  boot.initrd.availableKernelModules = [
    "xhci_pci"
    "usbhid"
    "usb_storage"
    "uas"
    "sd_mod"
    "ext4"
  ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ "vc4" ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos-root";
    fsType = "ext4";
    options = [ "noatime" ];
  };
  fileSystems."/boot/firmware" = {
    device = "/dev/disk/by-label/FIRMWARE";
    fsType = "vfat";
    options = [ "nofail" "noauto" ];
  };

  swapDevices = [ ];
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = true;
}
