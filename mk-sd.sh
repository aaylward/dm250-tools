#!/usr/bin/env bash
#
# mk-sd.sh — assemble a bootable SD-card image for the Pomera DM250.
#
# Inputs (in $KERNEL_SRC, default ~/src/linux-dm250):
#   arch/arm/boot/zImage
#   arch/arm/boot/dts/rockchip/pomera-dm250.dtb
#   modules-install/  (from `make modules_install INSTALL_MOD_PATH=modules-install`)
#
# Optional:
#   $FIRMWARE_DIR  — directory containing extracted /lib/firmware/brcm/* blobs.
#                    Copied into the rootfs if present.
#
# Output: an .img file you `dd` to an SD card.
#
# Designed to run inside a Linux container with --privileged (needs losetup).

set -euo pipefail

###############################################################################
# Config
###############################################################################
OUTPUT_IMG="${1:-sdcard.img}"
IMG_SIZE_MB="${IMG_SIZE_MB:-2048}"
BOOT_PART_MB="${BOOT_PART_MB:-256}"

KERNEL_SRC="${KERNEL_SRC:-$HOME/src/linux-dm250}"
WORKDIR="${WORKDIR:-$PWD/.mk-sd-work}"
FIRMWARE_DIR="${FIRMWARE_DIR:-}"

ALPINE_VERSION="${ALPINE_VERSION:-3.23.4}"
ALPINE_BRANCH="v$(echo "$ALPINE_VERSION" | cut -d. -f1,2)"
ALPINE_ARCH="armhf"
ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/${ALPINE_BRANCH}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"

UBOOT_REPO="${UBOOT_REPO:-https://source.denx.de/u-boot/u-boot.git}"
UBOOT_REF="${UBOOT_REF:-v2026.04}"
UBOOT_DEFCONFIG="${UBOOT_DEFCONFIG:-evb-rk3128_defconfig}"

RKBIN_REPO="${RKBIN_REPO:-https://github.com/rockchip-linux/rkbin.git}"
RKBIN_DDR_GLOB="${RKBIN_DDR_GLOB:-rk3128_ddr_*.bin}"
RKBIN_MINILOADER_GLOB="${RKBIN_MINILOADER_GLOB:-rk3128_miniloader_*.bin}"

CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"

###############################################################################
# Helpers
###############################################################################
log() { printf '[mk-sd] %s\n' "$*" >&2; }
die() { log "ERROR: $*"; exit 1; }

require_root() {
  [ "$(id -u)" = 0 ] || die "must run as root (losetup/mount need it)"
}

require_tools() {
  local missing=()
  for t in git make curl parted losetup mkfs.ext4 tar mkimage; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
  done
  [ "${#missing[@]}" -eq 0 ] || die "missing tools: ${missing[*]}
on debian: apt-get install -y git make curl parted util-linux e2fsprogs tar u-boot-tools"
}

require_kernel_artifacts() {
  [ -f "$KERNEL_SRC/arch/arm/boot/zImage" ] \
    || die "no zImage at $KERNEL_SRC/arch/arm/boot/zImage — build the kernel first"
  [ -f "$KERNEL_SRC/arch/arm/boot/dts/rockchip/pomera-dm250.dtb" ] \
    || die "no pomera-dm250.dtb — build with 'make dtbs'"
  [ -d "$KERNEL_SRC/modules-install" ] \
    || log "WARNING: no $KERNEL_SRC/modules-install — kernel will boot without modules.
      run: make modules_install INSTALL_MOD_PATH=modules-install"
}

cleanup() {
  if [ -n "${LOOPDEV:-}" ] && losetup "$LOOPDEV" >/dev/null 2>&1; then
    umount "$WORKDIR/mnt/boot" 2>/dev/null || true
    umount "$WORKDIR/mnt/root" 2>/dev/null || true
    losetup -d "$LOOPDEV" 2>/dev/null || true
  fi
}
trap cleanup EXIT

###############################################################################
# Step 1: build u-boot + idbloader
###############################################################################
build_uboot() {
  mkdir -p "$WORKDIR"

  if [ ! -d "$WORKDIR/u-boot" ]; then
    log "cloning u-boot $UBOOT_REF"
    git clone --depth 1 --branch "$UBOOT_REF" "$UBOOT_REPO" "$WORKDIR/u-boot"
  fi

  if [ ! -d "$WORKDIR/rkbin" ]; then
    log "cloning rkbin"
    git clone --depth 1 "$RKBIN_REPO" "$WORKDIR/rkbin"
  fi

  local ddr miniloader
  ddr=$(ls "$WORKDIR/rkbin/bin/rk31/"$RKBIN_DDR_GLOB 2>/dev/null | sort -V | tail -1) \
    || die "no DDR blob matching $RKBIN_DDR_GLOB in rkbin/bin/rk31/"
  miniloader=$(ls "$WORKDIR/rkbin/bin/rk31/"$RKBIN_MINILOADER_GLOB 2>/dev/null | sort -V | tail -1) \
    || die "no miniloader matching $RKBIN_MINILOADER_GLOB"
  log "using DDR=$(basename "$ddr"), miniloader=$(basename "$miniloader")"

  if [ ! -f "$WORKDIR/u-boot/u-boot.itb" ]; then
    log "configuring u-boot ($UBOOT_DEFCONFIG)"
    make -C "$WORKDIR/u-boot" "$UBOOT_DEFCONFIG"
    log "building u-boot (this takes a few minutes)"
    make -C "$WORKDIR/u-boot" CROSS_COMPILE="$CROSS_COMPILE" -j"$(nproc)"
  fi

  log "building idbloader.img"
  "$WORKDIR/u-boot/tools/mkimage" \
    -n rk3128 -T rksd \
    -d "$ddr:$miniloader" \
    "$WORKDIR/idbloader.img"

  [ -f "$WORKDIR/u-boot/u-boot.itb" ] \
    || die "u-boot.itb not produced — check $UBOOT_DEFCONFIG is correct for this u-boot version"
}

###############################################################################
# Step 2: fetch Alpine minirootfs
###############################################################################
fetch_alpine() {
  local tarball="$WORKDIR/alpine-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
  if [ ! -f "$tarball" ]; then
    log "downloading Alpine $ALPINE_VERSION $ALPINE_ARCH minirootfs"
    curl -fL -o "$tarball" "$ALPINE_URL"
  fi
  printf '%s\n' "$tarball"
}

###############################################################################
# Step 3: create + partition the image
###############################################################################
make_image() {
  log "creating $OUTPUT_IMG (${IMG_SIZE_MB} MiB sparse)"
  rm -f "$OUTPUT_IMG"
  truncate -s "${IMG_SIZE_MB}M" "$OUTPUT_IMG"

  # Layout:
  #   sector       0..63 : reserved (MBR/GPT)
  #   sector      64..  : idbloader.img
  #   sector   16384..  : u-boot.itb
  #   partition 1 starts at 32768 sectors (16 MiB)  — boot, ext4
  #   partition 2 follows                            — root, ext4
  local boot_start=32768
  local boot_end=$(( boot_start + BOOT_PART_MB * 2048 - 1 ))
  local root_start=$(( boot_end + 1 ))
  local total_sectors=$(( IMG_SIZE_MB * 2048 ))
  local root_end=$(( total_sectors - 1 ))

  log "partitioning: boot=${boot_start}-${boot_end}, root=${root_start}-${root_end}"
  parted -s "$OUTPUT_IMG" mklabel gpt
  parted -s "$OUTPUT_IMG" mkpart boot ext4 "${boot_start}s" "${boot_end}s"
  parted -s "$OUTPUT_IMG" mkpart root ext4 "${root_start}s" "${root_end}s"

  LOOPDEV=$(losetup -fP --show "$OUTPUT_IMG")
  log "attached $LOOPDEV"

  mkfs.ext4 -q -L boot "${LOOPDEV}p1"
  mkfs.ext4 -q -L root "${LOOPDEV}p2"

  mkdir -p "$WORKDIR/mnt/boot" "$WORKDIR/mnt/root"
  mount "${LOOPDEV}p1" "$WORKDIR/mnt/boot"
  mount "${LOOPDEV}p2" "$WORKDIR/mnt/root"
}

###############################################################################
# Step 4: populate /boot
###############################################################################
populate_boot() {
  local boot="$WORKDIR/mnt/boot"
  log "staging /boot"
  cp "$KERNEL_SRC/arch/arm/boot/zImage" "$boot/zImage"
  cp "$KERNEL_SRC/arch/arm/boot/dts/rockchip/pomera-dm250.dtb" "$boot/pomera-dm250.dtb"

  mkdir -p "$boot/extlinux"
  cat > "$boot/extlinux/extlinux.conf" <<'EOF'
default linux-dm250
prompt 0
timeout 1

label linux-dm250
    kernel /zImage
    fdt /pomera-dm250.dtb
    append earlycon=uart8250,mmio32,0x20064000 console=ttyS1,115200n8 root=/dev/mmcblk1p2 rw rootwait
EOF
}

###############################################################################
# Step 5: populate /
###############################################################################
populate_root() {
  local root="$WORKDIR/mnt/root"
  local tarball
  tarball=$(fetch_alpine)

  log "extracting Alpine minirootfs"
  tar -C "$root" -xzf "$tarball"

  if [ -d "$KERNEL_SRC/modules-install/lib/modules" ]; then
    log "installing kernel modules"
    mkdir -p "$root/lib/modules"
    cp -a "$KERNEL_SRC/modules-install/lib/modules/." "$root/lib/modules/"
  fi

  if [ -n "$FIRMWARE_DIR" ] && [ -d "$FIRMWARE_DIR" ]; then
    log "installing firmware blobs from $FIRMWARE_DIR"
    mkdir -p "$root/lib/firmware"
    cp -a "$FIRMWARE_DIR/." "$root/lib/firmware/"
  else
    log "no FIRMWARE_DIR set — Wi-Fi will not function until blobs added"
  fi

  # Bare-minimum first-boot: serial console getty, no password on root.
  log "configuring serial console + passwordless root"
  sed -i 's|^root:[^:]*:|root::|' "$root/etc/shadow"
  cat >> "$root/etc/inittab" <<'EOF'

# Pomera DM250 debug UART
ttyS1::respawn:/sbin/getty -L 115200 ttyS1 vt100
EOF

  # /etc/fstab so partition labels mount correctly
  cat > "$root/etc/fstab" <<'EOF'
LABEL=root  /      ext4   rw,relatime  0 1
LABEL=boot  /boot  ext4   rw,relatime  0 2
proc        /proc  proc   defaults     0 0
sysfs       /sys   sysfs  defaults     0 0
devpts      /dev/pts devpts gid=5,mode=620 0 0
tmpfs       /tmp   tmpfs  defaults     0 0
EOF

  # Hostname
  echo "dm250" > "$root/etc/hostname"

  sync
}

###############################################################################
# Step 6: write idbloader + u-boot to fixed sector offsets
###############################################################################
write_loaders() {
  log "writing idbloader to sector 64"
  dd if="$WORKDIR/idbloader.img" of="$LOOPDEV" seek=64 conv=notrunc status=none

  log "writing u-boot.itb to sector 16384"
  dd if="$WORKDIR/u-boot/u-boot.itb" of="$LOOPDEV" seek=16384 conv=notrunc status=none

  sync
}

###############################################################################
# Main
###############################################################################
require_root
require_tools
require_kernel_artifacts

build_uboot
make_image
populate_boot
populate_root
write_loaders

log "done. image: $OUTPUT_IMG"
log "flash with:  sudo dd if=$OUTPUT_IMG of=/dev/rdiskN bs=4m status=progress"
