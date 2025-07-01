#!/bin/bash

# Simple info/error for CI logs
info() {
  echo "[INFO] $1"
}
error() {
  echo "[ERROR] $1"
  exit 1
}

# Parameter settings
KERNEL_SUFFIX="-android14-@hipuu"
ENABLE_KPM=true
ENABLE_LZ4KD=true

# Device selection (fixed)
DEVICE_NAME="oneplus_ace5"
REPO_MANIFEST="oneplus_ace5.xml"

# Environment variables - separate ccache directory by device
export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
export CCACHE_NOHASHDIR="true"
export CCACHE_HARDLINK="true"
export CCACHE_DIR="$HOME/.ccache_${DEVICE_NAME}"
export CCACHE_MAXSIZE="8G"

# ccache init flag file per device
CCACHE_INIT_FLAG="$CCACHE_DIR/.ccache_initialized"

# Initialize ccache (first time only)
if command -v ccache >/dev/null 2>&1; then
    if [ ! -f "$CCACHE_INIT_FLAG" ]; then
        info "Initializing ccache for ${DEVICE_NAME} for the first time..."
        mkdir -p "$CCACHE_DIR" || error "Failed to create ccache directory"
        ccache -M "$CCACHE_MAXSIZE"
        touch "$CCACHE_INIT_FLAG"
    else
        info "ccache (${DEVICE_NAME}) already initialized, skipping..."
    fi
else
    info "ccache not installed, skipping initialization"
fi

# Working directory - separate per device
WORKSPACE="$GITHUB_WORKSPACE/kernel_${DEVICE_NAME}"
mkdir -p "$WORKSPACE" || error "Failed to create working directory"
cd "$WORKSPACE" || error "Failed to enter working directory"

# Install repo tool (only if not installed)
if ! command -v repo >/dev/null 2>&1; then
    info "Installing repo tool..."
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > ~/repo || error "Failed to download repo"
    chmod a+x ~/repo
    mv ~/repo /usr/local/bin/repo || error "Failed to install repo"
else
    info "Repo tool already installed, skipping"
fi

# Source Code Management
KERNEL_WORKSPACE="$WORKSPACE/kernel_workspace"
mkdir -p "$KERNEL_WORKSPACE" || error "Failed to create kernel_workspace directory"
cd "$KERNEL_WORKSPACE" || error "Failed to enter kernel_workspace directory"

info "Initializing repo and syncing source code..."
repo init -u https://github.com/OnePlusOSS/kernel_manifest.git -b refs/heads/oneplus/sm8650 -m "$REPO_MANIFEST" --depth=1 || error "Repo initialization failed"
repo --trace sync -c -j$(nproc --all) --no-tags || error "Repo sync failed"

# Clean dirty tags
info "Cleaning dirty tags and ABI protections..."
for f in kernel_platform/{common,msm-kernel,external/dtc}/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  grep -q 'res=.*s/-dirty' "$f" || sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
  sed -i '$s|echo "\$res"|echo "$KERNEL_SUFFIX"|' "$f"
done

# Setup KernelSU
cd kernel_platform || error "Failed to enter kernel_platform"
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-main
cd KernelSU || error "Failed to enter KernelSU directory"
KSU_VERSION=$(expr $(/usr/bin/git rev-list --count main) + 10700)
export KSU_VERSION=$KSU_VERSION
sed -i "s/DKSU_VERSION=12800/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile || error "Failed to modify KernelSU version"

# Inject version string for app display
echo "#define VERSION_NAME \"v${KSU_VERSION}@hipuu\"" > include/version_name.h
grep -q 'version_name.h' kernel/Makefile || sed -i '1i -include include/version_name.h' kernel/Makefile

# Add defconfig
DEFCONFIG=./common/arch/arm64/configs/gki_defconfig
cat <<EOF >> "$DEFCONFIG"
CONFIG_KSU=y
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_NET_SCH_FQ=y
EOF

if [ "${ENABLE_KPM}" = "true" ]; then
  echo "CONFIG_KPM=y" >> "$DEFCONFIG"
fi

# Remove check_defconfig
sed -i 's/check_defconfig//' ./common/build.config.gki

# Toolchain paths
export CLANG_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin"
export RUSTC_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/rust/linux-x86/1.73.0b/bin/rustc"
export PAHOLE_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
export PATH="$CLANG_PATH:/usr/lib/ccache:$PATH"

# Build kernel
cd $KERNEL_WORKSPACE/kernel_platform/common
make LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" PAHOLE="$PAHOLE_PATH" LD=ld.lld HOSTLD=ld.lld \
  O=out KCFLAGS+=-O2 gki_defconfig
make -j$(nproc) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" PAHOLE="$PAHOLE_PATH" LD=ld.lld HOSTLD=ld.lld \
  O=out KCFLAGS+=-O2 Image

# AnyKernel3 packaging
cd "$WORKSPACE" || error "Failed to return to workspace"
git clone -q https://github.com/thaihong339/AnyKernel3.git --depth=1 || info "AnyKernel3 already exists"
rm -rf ./AnyKernel3/.git ./AnyKernel3/push.sh
cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" ./AnyKernel3/ || error "Failed to copy Image"
cd AnyKernel3 || error "Failed to enter AnyKernel3 directory"
zip -r "AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" ./* || error "Packaging failed"

# Output artifacts
OUTPUT_DIR="${GITHUB_WORKSPACE:-$PWD}/output"
mkdir -p "$OUTPUT_DIR" || error "Failed to create output directory"
cp "$WORKSPACE/AnyKernel3/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" "$OUTPUT_DIR/"
cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" "$OUTPUT_DIR/"

info "Kernel package path: $OUTPUT_DIR/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip"
info "Image path: $OUTPUT_DIR/Image"
info "Build complete. Artifacts are in $OUTPUT_DIR"
