# Builder image for Pomera DM250 kernel + SD-card assembly.
#
# Build (on Apple Silicon):
#   docker build --platform=linux/arm64 -t dm250-builder ~/src/dm250-tools
#
# Use:
#   docker run --rm -it --platform=linux/arm64 \
#       -v ~/src/linux-dm250:/build/linux-dm250 \
#       -v ~/src/dm250-tools:/build/tools \
#       -w /build dm250-builder bash
#
# For mk-sd.sh, add --privileged (needs losetup/mount).

FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        # kernel build
        build-essential \
        bc bison flex \
        libssl-dev libelf-dev \
        cpio kmod rsync \
        gcc-arm-linux-gnueabihf \
        # SD-card image assembly
        parted util-linux e2fsprogs dosfstools \
        u-boot-tools \
        # general
        git curl ca-certificates \
        python3 xz-utils zstd \
        sudo less vim-tiny \
    && rm -rf /var/lib/apt/lists/*

# Kernel + u-boot expect these for cross-compile
ENV ARCH=arm \
    CROSS_COMPILE=arm-linux-gnueabihf-

WORKDIR /build

CMD ["bash"]
