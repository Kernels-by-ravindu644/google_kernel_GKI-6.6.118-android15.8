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
#   6.6.118-android15-8-Nethunter-DS-KSUN@ravindu644-<sha>-4k
KMI="$(sed -n 's/^BRANCH=\([^-]*\).*/\1/p' build.config.common)-$(sed -n 's/^KMI_GENERATION=//p' build.config.common)"
LOCALVERSION_SUFFIX="-${KMI}-Nethunter-DS-KSUN@ravindu644-$(git log -1 --pretty=%h)"
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
    make "${BUILD_OPTIONS[@]}" gki_defconfig custom.config droidspaces.config nethunter.config || \
        die "Failed to generate the kernel configuration."

    # configure the kernel
    #make "${BUILD_OPTIONS[@]}" menuconfig

    # build the kernel (Image + all =m modules, e.g. the rtl8821au Wi-Fi driver)
    make "${BUILD_OPTIONS[@]}" || die "Kernel build failed."

    # copy the built kernel to the dist directory
    [ -f "${SCRIPT_DIR}/out/arch/arm64/boot/Image" ] || die "Build finished but no Image was produced."
    cp "${SCRIPT_DIR}/out/arch/arm64/boot/Image" "${SCRIPT_DIR}/dist"

    RELEASE="$(cat "${SCRIPT_DIR}/out/include/config/kernel.release")"
    echo -e "\nKernel release: ${RELEASE}\n"
    [ "${RELEASE}" = "${KERNEL_VERSION}${LOCALVERSION_SUFFIX}-4k" ] || \
        die "Unexpected release string -- the localversion setup is broken."

    # install modules (signed + stripped) into dist/modules with depmod metadata,
    # so `modprobe -d dist/modules 8821au` resolves the cfg80211 dependency.
    rm -rf "${SCRIPT_DIR}/dist/modules"
    make "${BUILD_OPTIONS[@]}" INSTALL_MOD_PATH="${SCRIPT_DIR}/dist/modules" \
        INSTALL_MOD_STRIP=1 modules_install || die "modules_install failed."
    find "${SCRIPT_DIR}/dist/modules" -name '8821au.ko' | grep -q . || \
        die "Build finished but 8821au.ko was not produced."
    find "${SCRIPT_DIR}/dist/modules" -name 'mt76x0u.ko' | grep -q . || \
        die "Build finished but mt76x0u.ko was not produced."
    echo -e "\nModules staged under dist/modules:"
    find "${SCRIPT_DIR}/dist/modules" -name '*.ko' -printf '  %P\n'
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

# KernelSU module: kernelsu-module/ skeleton + the .ko files listed in its
# load.conf (from dist/modules) + the firmware blobs from prebuilts/firmware.
pack_ksu_module(){
    local src="${SCRIPT_DIR}/kernelsu-module"
    local stage="${SCRIPT_DIR}/out/ksu-module"
    rm -rf "${stage}" && mkdir -p "${stage}"
    cp -r "${src}/." "${stage}/"
    find "${stage}" -name .gitkeep -delete

    sed -e "s|@VERSION@|${RELEASE_TAG}|" -e "s|@VERSIONCODE@|${BUILD_DATE}|" \
        -i "${stage}/module.prop"

    local ko
    for ko in $(sed -e 's/#.*//' "${src}/load.conf"); do
        cp "$(find "${SCRIPT_DIR}/dist/modules" -name "${ko}" | head -n1)" "${stage}/modules/" 2>/dev/null || \
            die "load.conf lists ${ko} but the build did not produce it."
    done
    cp -r "${SCRIPT_DIR}/prebuilts/firmware/." "${stage}/system/vendor/firmware/"

    KSU_MODULE_ZIP="${SCRIPT_DIR}/dist/nethunter-wifi-drivers-${RELEASE_TAG}.zip"
    rm -f "${KSU_MODULE_ZIP}"
    (cd "${stage}" && zip -q -X -r "${KSU_MODULE_ZIP}" .) || die "Failed to zip the KernelSU module."
    rm -rf "${stage}"
}

# Release zip: boot.img + the KernelSU module zip.
pack_release(){
    local zip="${SCRIPT_DIR}/dist/Pixel-10-Pro-KSUN-${KSU_VERSION}-NH-DS-${RELEASE_TAG}.zip"
    rm -f "${zip}"
    (cd "${SCRIPT_DIR}/dist" && zip -q -X "${zip}" boot.img "$(basename "${KSU_MODULE_ZIP}")") || \
        die "Failed to create the release zip."
    echo -e "\nRelease: ${zip}"
    sha256sum "${zip}"
}

BUILD_DATE="$(date +%Y%m%d)"
RELEASE_TAG="${BUILD_DATE}-$(git log -1 --pretty=%h)"
KSU_VERSION="$(git -C "${SCRIPT_DIR}/KernelSU-Next" describe --tags --abbrev=0 2>/dev/null || echo unknown)"

echo "Building kernel..." && \
    build_kernel && \
    echo "Packing boot image..." && \
    pack_bootimg && \
    echo "Packing KernelSU module..." && \
    pack_ksu_module && \
    pack_release
