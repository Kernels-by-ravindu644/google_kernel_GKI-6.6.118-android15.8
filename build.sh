#!/bin/bash
# Copyright (c) 2026 ravindu644 <droidcasts@protonmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build script for Pixel 10 Pro kernel (6.6.118)

set -euo pipefail

SCRIPT_DIR="$(dirname $(readlink -fq "$0"))"
MAGISKBOOT="${SCRIPT_DIR}/tools/magiskboot"
BOOTIMG="${SCRIPT_DIR}/prebuilts/boot.img"
cd "${SCRIPT_DIR}"

die(){ echo -e "\nError: $*" >&2 ; exit 1 ; }

# prebuilts this script uses only support x86_64 linux
[ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ] || \
    die "This script only runs on x86_64 Linux."

KERNEL_VERSION="$(make kernelversion 2>/dev/null)"

# init & update git submodules
git submodule update --init --recursive

# download & install clang-r510928
if [ ! -d "${HOME}/toolchains/clang-r510928" ]; then
    echo -e "Cloning clang-r510928..."
    mkdir -p "${HOME}/toolchains/clang-r510928" && cd "${HOME}/toolchains/clang-r510928"

    curl -LO "https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains/clang-r510928.tar.gz" || {
    echo "Failed to download clang-r510928. Please check your internet connection and try again." && exit 1
    }

    tar -xf clang-r510928.tar.gz && rm clang-r510928.tar.gz
    cd "${SCRIPT_DIR}"
fi

# cleanup before building
rm -rf "${SCRIPT_DIR}/"{out,dist} && \
    mkdir -p "${SCRIPT_DIR}/"{out,dist}

# generate localversion -- kbuild doesn't know the KMI tag, so write it here:
#   6.6.118-android15-8-ravindu644-<sha>-4k
KMI="$(sed -n 's/^BRANCH=\([^-]*\).*/\1/p' build.config.common)-$(sed -n 's/^KMI_GENERATION=//p' build.config.common)"
LOCALVERSION_SUFFIX="-${KMI}-ravindu644-$(git log -1 --pretty=%h)"
printf '%s' "${LOCALVERSION_SUFFIX}" > "${SCRIPT_DIR}/out/localversion"
export LOCALVERSION=""   # keeps setlocalversion from appending a '+'

# export toolchain paths
export PATH="${HOME}/toolchains/clang-r510928/bin:${PATH}"

# build options for the kernel
export BUILD_OPTIONS=(
    -C "${SCRIPT_DIR}"
    O="${SCRIPT_DIR}/out"
    -j$(nproc)
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    HOSTCC=gcc
    HOSTCXX=g++
)

build_kernel(){
    # make default configuration.
    make "${BUILD_OPTIONS[@]}" gki_defconfig custom.config || \
        die "Failed to generate the kernel configuration."

    # configure the kernel
    #make "${BUILD_OPTIONS[@]}" menuconfig

    # build the kernel
    make "${BUILD_OPTIONS[@]}" || die "Kernel build failed."

    # copy the built kernel to the dist directory
    [ -f "${SCRIPT_DIR}/out/arch/arm64/boot/Image" ] || die "Build finished but no Image was produced."
    cp "${SCRIPT_DIR}/out/arch/arm64/boot/Image" "${SCRIPT_DIR}/dist"

    RELEASE="$(cat "${SCRIPT_DIR}/out/include/config/kernel.release")"
    echo -e "\nKernel release: ${RELEASE}\n"
    [ "${RELEASE}" = "${KERNEL_VERSION}${LOCALVERSION_SUFFIX}-4k" ] || \
        die "Unexpected release string -- the localversion setup is broken."
}

pack_bootimg(){
    [ -x "${MAGISKBOOT}" ] || die "magiskboot is missing or not executable: ${MAGISKBOOT}"
    [ -f "${BOOTIMG}" ] || die "Prebuilt boot image not found: ${BOOTIMG}"
    [ -f "${SCRIPT_DIR}/dist/Image" ] || die "dist/Image not found. Build the kernel first."

    # unpack/repack in a scratch dir so leftovers never pollute dist/
    local workdir="${SCRIPT_DIR}/out/bootimg"
    rm -rf "${workdir}" && mkdir -p "${workdir}"
    cd "${workdir}"

    "${MAGISKBOOT}" unpack "${BOOTIMG}" || die "Failed to unpack ${BOOTIMG}"
    cp "${SCRIPT_DIR}/dist/Image" kernel
    "${MAGISKBOOT}" repack "${BOOTIMG}" || die "Failed to repack ${BOOTIMG}"
    [ -f new-boot.img ] || die "magiskboot did not produce new-boot.img"
    mv new-boot.img "${SCRIPT_DIR}/dist/boot.img"

    cd "${SCRIPT_DIR}" && rm -rf "${workdir}"
}

echo "Building kernel..." && \
    build_kernel && \
    echo "Packing boot image..." && \
    pack_bootimg
