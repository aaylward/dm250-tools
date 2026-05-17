#!/usr/bin/env bash
#
# configure-kernel.sh — generate a working .config for the Pomera DM250.
#
# Starts from multi_v7_defconfig and enables every DM250-specific option
# identified by tracing DT compatibles to Kconfig symbols.
#
# Run inside the dm250-builder container, from /build/linux-dm250.

set -euo pipefail

if [ ! -f Makefile ] || ! grep -q '^NAME = ' Makefile 2>/dev/null; then
    echo "error: run this from the kernel source root" >&2
    exit 1
fi

export ARCH="${ARCH:-arm}"
export CROSS_COMPILE="${CROSS_COMPILE:-arm-linux-gnueabihf-}"

echo "[1/3] generating base config from multi_v7_defconfig"
make multi_v7_defconfig

echo "[2/3] enabling DM250-specific options"

# Built-in (need them before rootfs mounts, or required by hardware bringup)
BUILT_IN=(
    # PMIC / regulators / RTC
    MFD_RK8XX_I2C REGULATOR_RK808 RTC_DRV_RK808
    REGULATOR_FIXED_VOLTAGE

    # I2C bus (PMIC + TC35894 live here)
    I2C_RK3X

    # MMC root path
    MMC_DW MMC_DW_ROCKCHIP PWRSEQ_SIMPLE

    # Keyboard chip + GPIO bank
    MFD_TC3589X KEYBOARD_TC3589X GPIO_TC3589X

    # Hardware buttons
    KEYBOARD_GPIO

    # Display: VOP + LVDS bridge + panel
    DRM_ROCKCHIP ROCKCHIP_VOP ROCKCHIP_LVDS DRM_PANEL_LVDS

    # PWM backlight
    BACKLIGHT_PWM PWM_ROCKCHIP

    # Watchdog + thermal
    DW_WATCHDOG ROCKCHIP_THERMAL

    # SARADC (battery sense)
    ROCKCHIP_SARADC

    # Filesystem for rootfs (Alpine uses ext4 by default)
    EXT4_FS
)

# Loadable modules (loaded after rootfs is up)
MODULES=(
    DRM_LIMA
    BRCMFMAC BRCMFMAC_SDIO CFG80211 MAC80211
    BT BT_HCIUART BT_HCIUART_BCM BT_BCM
    LEDS_GPIO NEW_LEDS LEDS_CLASS
)

for sym in "${BUILT_IN[@]}"; do
    ./scripts/config --enable "$sym"
done

for sym in "${MODULES[@]}"; do
    ./scripts/config --module "$sym"
done

echo "[3/3] resolving dependencies (olddefconfig)"
make olddefconfig

echo
echo "done. verifying critical symbols:"
grep -E "^CONFIG_(ARCH_ROCKCHIP|MFD_RK8XX_I2C|MFD_TC3589X|KEYBOARD_TC3589X|MMC_DW_ROCKCHIP|DRM_ROCKCHIP|ROCKCHIP_LVDS|BACKLIGHT_PWM|RTC_DRV_RK808|DW_WATCHDOG|BRCMFMAC|DRM_LIMA)=" .config \
  | sort \
  || echo "WARNING: some symbols missing — inspect .config"
