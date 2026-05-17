# dm250-tools

Small helpers for working with the Pomera DM250 from a Mac.

## `mk-sd.sh` — build a bootable SD card image

Produces a single `.img` file you `dd` to an SD card. Boots a minimal Alpine
Linux on the DM250 from your custom kernel.

### What it does

1. Builds mainline u-boot for RK3128 (`evb-rk3128_defconfig`).
2. Combines Rockchip's DDR init blob + miniloader from `rkbin` into
   `idbloader.img` via `mkimage`.
3. Downloads the Alpine `armhf` minirootfs (~3 MB).
4. Creates a 2 GB GPT image, two ext4 partitions (boot + root).
5. Stages your `zImage`, `pomera-dm250.dtb`, `extlinux.conf`, Alpine rootfs,
   kernel modules, and (optional) firmware blobs.
6. Writes `idbloader.img` to sector 64 and `u-boot.itb` to sector 16384.

### Prereqs

You need a Linux environment with root + loopdev access. The included
`Dockerfile` bundles everything for both kernel build and SD-card assembly.

```sh
# One-time: build the builder image
docker build --platform=linux/arm64 -t dm250-builder ~/src/dm250-tools
```

The image is `linux/arm64` (native on Apple Silicon) with the
`arm-linux-gnueabihf` cross toolchain inside &mdash; runs at near-native speed.

You also need a kernel that's already been built:
```
cd ~/src/linux-dm250
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- multi_v7_defconfig
# ... (apply config gaps from build-on-apple-silicon.html) ...
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- -j"$(nproc)" zImage modules dtbs
make ARCH=arm CROSS_COMPILE=arm-linux-gnueabihf- \
  INSTALL_MOD_PATH=modules-install modules_install
```

### Usage

Two steps:

```sh
# 1. Build the image (inside a privileged Linux container)
docker run --rm --privileged \
  -v "$HOME/src/linux-dm250":/build/linux-dm250 \
  -v "$HOME/src/dm250-tools":/build/tools \
  -w /build \
  dm250-builder \
  /build/tools/mk-sd.sh /build/sdcard.img

# 2. Flash to SD card from macOS host
diskutil list                                    # find the right disk
diskutil unmountDisk /dev/diskN
sudo dd if=~/src/linux-dm250/sdcard.img \
        of=/dev/rdiskN bs=4m status=progress
sync
```

### Knobs (environment variables)

| Variable | Default | Purpose |
|---|---|---|
| `KERNEL_SRC` | `~/src/linux-dm250` | Where to find `zImage`, `dtb`, `modules-install/` |
| `FIRMWARE_DIR` | (unset) | Directory of extracted `/lib/firmware/` to copy into rootfs |
| `IMG_SIZE_MB` | `2048` | Total image size |
| `BOOT_PART_MB` | `256` | Size of /boot partition |
| `ALPINE_VERSION` | `3.23.4` | Alpine release |
| `UBOOT_REF` | `v2026.04` | u-boot tag to build |
| `UBOOT_DEFCONFIG` | `evb-rk3128_defconfig` | u-boot board defconfig |

### First boot

- Serial console on `uart1` (115200 8N1). Without a console you fly blind.
- Root login, **no password**. Set one immediately on first boot.
- Wi-Fi is dead unless you populated `FIRMWARE_DIR` with the brcmfmac blobs
  extracted from the stock eMMC dump (see `build-on-apple-silicon.html`).

### Notes

- The script is idempotent on its work directory (`.mk-sd-work/`). Re-running
  reuses the u-boot build and Alpine tarball; only the image is rebuilt.
- Output image is sparse — `du -sh sdcard.img` reports actual on-disk size,
  not the 2 GB allocation.
- macOS-specific: `dd` to `/dev/rdiskN` (raw), not `/dev/diskN` (buffered).
  `r`-prefix is ~10× faster.
