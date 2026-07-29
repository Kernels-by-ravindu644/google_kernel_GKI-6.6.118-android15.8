#!/bin/bash
# Copyright (c) 2026 ravindu644 <droidcasts@protonmail.com>
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Build script for Pixel 10 Pro kernel (6.6.118)

set -euo pipefail

SCRIPT_DIR="$(dirname $(readlink -fq "$0"))"
cd "${SCRIPT_DIR}"

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
    make "${BUILD_OPTIONS[@]}" gki_defconfig

    # configure the kernel
    #make "${BUILD_OPTIONS[@]}" menuconfig

    # build the kernel
    make "${BUILD_OPTIONS[@]}"

    # copy the built kernel to the dist directory
    cp "${SCRIPT_DIR}/out/arch/arm64/boot/Image" "${SCRIPT_DIR}/dist"
}

echo "Building kernel..." && \
    build_kernel
