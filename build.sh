#!/bin/bash
# Copyright (c) 2026 ravindu644 <droidcasts@protonmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Linux 6.6 arm64 (GKI) kernel build script for the Pixel 10 Pro

set -euo pipefail

# cd to the repo root
KERNEL_ROOT="$(dirname "$(readlink -f "$0")")"
cd "${KERNEL_ROOT}"

# init submodules
git submodule update --init --recursive

# release tag: CI sets it so the GitHub release and the zip names agree
BUILD_VERSION="$(git log -1 --pretty=%h)"
RELEASE_TAG="${RELEASE_TAG:-$(date +%Y%m%d)-${BUILD_VERSION}}"
KSU_VERSION="$(git -C KernelSU-Next describe --tags --abbrev=0 2>/dev/null || echo unknown)"

# generate localversion. kbuild does not know the KMI tag, so write it here:
#   6.6.118-android15-8-Nethunter-DS-KSUN@ravindu644-<sha>-4k
rm -rf dist && mkdir -p out dist
KMI="$(sed -n 's/^BRANCH=\([^-]*\).*/\1/p' build.config.common)-$(sed -n 's/^KMI_GENERATION=//p' build.config.common)"
printf '%s' "-${KMI}-Nethunter-DS-KSUN@ravindu644-${BUILD_VERSION}" > out/localversion
export LOCALVERSION=""   # keeps setlocalversion from appending a '+'

# export toolchain path and core variables
export PATH="${HOME}/toolchains/clang-r510928/bin:${PATH}"
MAGISKBOOT="${KERNEL_ROOT}/tools/magiskboot"
STOCK_BOOT="${KERNEL_ROOT}/prebuilts/boot.img"

# download the toolchain if it isn't there yet
download_toolchains(){
    local base="https://github.com/ravindu644/Android-Kernel-Tutorials/releases/download/toolchains"
    if [ ! -x "${HOME}/toolchains/clang-r510928/bin/clang" ]; then
        echo "[INFO]: downloading clang-r510928..."
        mkdir -p "${HOME}/toolchains/clang-r510928"
        curl -fL "${base}/clang-r510928.tar.gz" | tar -xz -C "${HOME}/toolchains/clang-r510928" || \
            { rm -rf "${HOME}/toolchains/clang-r510928"; exit 1; }
    fi
}

# build options for the kernel
BUILD_OPTIONS=(
    -C "${KERNEL_ROOT}"
    O="${KERNEL_ROOT}/out"
    -j"$(nproc)"
    ARCH=arm64
    LLVM=1
    LLVM_IAS=1
    HOSTCC=gcc
    HOSTCXX=g++
)

build_kernel(){
    make "${BUILD_OPTIONS[@]}" gki_defconfig custom.config droidspaces.config nethunter.config

    # menuconfig
    #make "${BUILD_OPTIONS[@]}" menuconfig

    # Image + every =m module (the out-of-tree Wi-Fi drivers)
    make "${BUILD_OPTIONS[@]}"
    cp out/arch/arm64/boot/Image dist/Image

    # modules_install is what signs them, so the .ko files have to come from here
    rm -rf dist/modules
    make "${BUILD_OPTIONS[@]}" INSTALL_MOD_PATH="${KERNEL_ROOT}/dist/modules" INSTALL_MOD_STRIP=1 modules_install
}

build_boot(){
    # unpack stock boot.img, swap in our kernel, repack
    local work="${KERNEL_ROOT}/out/boot_work"
    rm -rf "${work}" && mkdir -p "${work}" && cd "${work}"
    "${MAGISKBOOT}" unpack "${STOCK_BOOT}"
    cp "${KERNEL_ROOT}/dist/Image" kernel
    "${MAGISKBOOT}" repack "${STOCK_BOOT}" "${KERNEL_ROOT}/dist/boot.img"
    cd "${KERNEL_ROOT}" && rm -rf "${work}"
}

build_ksu_module(){
    # kernelsu-module/ skeleton + the .ko files load.conf names + the firmware blobs
    local stage="${KERNEL_ROOT}/out/ksu-module"
    rm -rf "${stage}" && cp -r kernelsu-module "${stage}"
    sed -i "s|@VERSION@|${RELEASE_TAG}|; s|@VERSIONCODE@|$(date +%Y%m%d)|" "${stage}/module.prop"
    cp -r prebuilts/firmware/. "${stage}/system/vendor/firmware/"

    local ko
    for ko in $(sed 's/#.*//' kernelsu-module/load.conf); do
        find dist/modules -name "${ko}" -exec cp {} "${stage}/modules/" \; -quit
        [ -f "${stage}/modules/${ko}" ] || { echo "load.conf lists ${ko} but the build did not produce it" >&2; exit 1; }
    done

    KSU_MODULE_ZIP="nethunter-wifi-drivers-${RELEASE_TAG}.zip"
    (cd "${stage}" && zip -q -X -r "${KERNEL_ROOT}/dist/${KSU_MODULE_ZIP}" .)
    rm -rf "${stage}"
}

build_zip(){
    # release zip: boot.img + the KernelSU module zip
    cd "${KERNEL_ROOT}/dist"
    zip -q -X "Pixel-10-Pro-KSUN-${KSU_VERSION}-NH-DS-${RELEASE_TAG}.zip" boot.img "${KSU_MODULE_ZIP}"
    echo -e "\n[INFO]: ZIP BUILT SUCCESSFULLY..!\n"
    cd "${KERNEL_ROOT}"
}

download_toolchains
build_kernel
build_boot
build_ksu_module
build_zip
