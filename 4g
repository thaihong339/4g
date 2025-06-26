#!/bin/bash

# Color definitions
info() {
  tput setaf 3
  echo "[INFO] $1"
  tput sgr0
}

error() {
  tput setaf 1
  echo "[ERROR] $1"
  tput sgr0
  exit 1
}

# Parameter settings
KERNEL_SUFFIX="-android14-TG"
ENABLE_KPM=true
ENABLE_LZ4KD=true

# Device fixed to Ace 5
DEVICE_NAME="oneplus_ace5"
REPO_MANIFEST="oneplus_ace5.xml"

# Custom kernel suffix
read -p "Enter kernel name suffix (supports emoji, press enter to use default): " input_suffix
if [ -n "$input_suffix" ]; then
    KERNEL_SUFFIX="$input_suffix"
fi

read -p "Enable KPM? (Default: enabled) [y/N]: " kpm
if [[ "$kpm" =~ [yY] ]]; then
    ENABLE_KPM=true
else
    ENABLE_KPM=false
fi

read -p "Enable lz4+zstd? (Default: enabled) [y/N]: " lz4
if [[ "$lz4" =~ [yY] ]]; then
    ENABLE_LZ4KD=true
else
    ENABLE_LZ4KD=false
fi

# Environment variables - ccache directory per device
export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
export CCACHE_NOHASHDIR="true"
export CCACHE_HARDLINK="true"
export CCACHE_DIR="$HOME/.ccache_${DEVICE_NAME}"
export CCACHE_MAXSIZE="8G"

CCACHE_INIT_FLAG="$CCACHE_DIR/.ccache_initialized"

if command -v ccache >/dev/null 2>&1; then
    if [ ! -f "$CCACHE_INIT_FLAG" ]; then
        info "Initializing ccache for ${DEVICE_NAME}..."
        mkdir -p "$CCACHE_DIR" || error "Failed to create ccache directory"
        ccache -M "$CCACHE_MAXSIZE"
        touch "$CCACHE_INIT_FLAG"
    else
        info "ccache (${DEVICE_NAME}) already initialized, skipping..."
    fi
else
    info "ccache not installed, skipping initialization"
fi

WORKSPACE="$HOME/kernel_${DEVICE_NAME}"
mkdir -p "$WORKSPACE" || error "Failed to create working directory"
cd "$WORKSPACE" || error "Failed to enter working directory"

# Check and install dependencies
info "Checking and installing dependencies..."
DEPS=(python3 git curl ccache flex bison libssl-dev libelf-dev bc zip)
MISSING_DEPS=()

for pkg in "${DEPS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_DEPS+=("$pkg")
    fi
done

if [ ${#MISSING_DEPS[@]} -eq 0 ]; then
    info "All dependencies are installed, skipping installation."
else
    info "Missing dependencies: ${MISSING_DEPS[*]}, installing..."
    sudo apt update || error "System update failed"
    sudo apt install -y "${MISSING_DEPS[@]}" || error "Dependency installation failed"
fi

# Install repo tool (first time only)
if ! command -v repo >/dev/null 2>&1; then
    info "Installing repo tool..."
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > ~/repo || error "Failed to download repo"
    chmod a+x ~/repo
    sudo mv ~/repo /usr/local/bin/repo || error "Failed to install repo"
else
    info "repo tool already installed, skipping"
fi

# ==================== Source Management ====================

KERNEL_WORKSPACE="$WORKSPACE/kernel_workspace"
mkdir -p "$KERNEL_WORKSPACE" || error "Failed to create kernel_workspace directory"
cd "$KERNEL_WORKSPACE" || error "Failed to enter kernel_workspace directory"

info "Initializing repo and syncing source..."
repo init -u https://github.com/OnePlusOSS/kernel_manifest.git -b refs/heads/oneplus/sm8650 -m "$REPO_MANIFEST" --depth=1 || error "Repo init failed"
repo --trace sync -c -j$(nproc --all) --no-tags || error "Repo sync failed"

# ==================== Core Build Steps ====================

info "Cleaning dirty flags and ABI protection..."
for d in kernel_platform/common kernel_platform/msm-kernel; do
  rm "$d"/android/abi_gki_protected_exports_* 2>/dev/null || echo "No protected exports in $d!"
done
for f in kernel_platform/{common,msm-kernel,external/dtc}/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  grep -q 'res=.*s/-dirty' "$f" || sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
done

info "Modifying kernel name..."
sed -i '$s|echo "\$res"|echo "'"$KERNEL_SUFFIX"'"|' kernel_platform/common/scripts/setlocalversion
sed -i '$s|echo "\$res"|echo "'"$KERNEL_SUFFIX"'"|' kernel_platform/msm-kernel/scripts/setlocalversion
sed -i '$s|echo "\$res"|echo "'"$KERNEL_SUFFIX"'"|' kernel_platform/external/dtc/scripts/setlocalversion

# Setup SukiSU
info "Setting up SukiSU..."
cd kernel_platform || error "Failed to enter kernel_platform"
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-main
cd KernelSU || error "Failed to enter KernelSU directory"
KSU_VERSION=$(expr $(/usr/bin/git rev-list --count main) "+" 10700)
export KSU_VERSION=$KSU_VERSION
sed -i "s/DKSU_VERSION=12800/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile || error "Failed to modify KernelSU version"

# Setup susfs
info "Setting up susfs..."
cd "$KERNEL_WORKSPACE" || error "Failed to return to workspace"
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android14-6.1 || info "susfs4ksu already exists or clone failed"
git clone https://github.com/Xiaomichael/kernel_patches.git || info "kernel_patches already exists or clone failed"
git clone -q https://github.com/SukiSU-Ultra/SukiSU_patch.git || info "SukiSU_patch already exists or clone failed"

cd kernel_platform || error "Failed to enter kernel_platform"
cp ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./common/
cp ../kernel_patches/next/syscall_hooks.patch ./common/
cp ../susfs4ksu/kernel_patches/fs/* ./common/fs/
cp ../susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

if [ "${ENABLE_LZ4KD}" == "true" ]; then
    cp ../kernel_patches/001-lz4.patch ./common/
    cp ../kernel_patches/lz4armv8.S ./common/lib
    cp ../kernel_patches/002-zstd.patch ./common/
fi

cd $KERNEL_WORKSPACE/kernel_platform/common || { echo "Failed to enter common directory"; exit 1; }

patch -p1 < 50_add_susfs_in_gki-android14-6.1.patch || true
cp ../../kernel_patches/69_hide_stuff.patch ./
patch -p1 -F 3 < 69_hide_stuff.patch
patch -p1 -F 3 < syscall_hooks.patch

if [ "${ENABLE_LZ4KD}" == "true" ]; then
    git apply -p1 < 001-lz4.patch || true
    patch -p1 < 002-zstd.patch || true
fi

cd $KERNEL_WORKSPACE/kernel_platform

info "Adding SUSFS configuration..."
DEFCONFIG=./common/arch/arm64/configs/gki_defconfig
cat <<EOF >> "$DEFCONFIG"
CONFIG_KSU=y
CONFIG_KSU_SUSFS_SUS_SU=n
CONFIG_KSU_MANUAL_HOOK=y
CONFIG_KSU_SUSFS=y
CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT=y
CONFIG_KSU_SUSFS_SUS_PATH=y
CONFIG_KSU_SUSFS_SUS_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SUS_KSTAT=y
CONFIG_KSU_SUSFS_SUS_OVERLAYFS=n
CONFIG_KSU_SUSFS_TRY_UMOUNT=y
CONFIG_KSU_SUSFS_AUTO_ADD_TRY_UMOUNT_FOR_BIND_MOUNT=y
CONFIG_KSU_SUSFS_SPOOF_UNAME=y
CONFIG_KSU_SUSFS_ENABLE_LOG=y
CONFIG_KSU_SUSFS_HIDE_KSU_SUSFS_SYMBOLS=y
CONFIG_KSU_SUSFS_SPOOF_CMDLINE_OR_BOOTCONFIG=y
CONFIG_KSU_SUSFS_OPEN_REDIRECT=y
CONFIG_TCP_CONG_ADVANCED=y
CONFIG_TCP_CONG_BBR=y
CONFIG_NET_SCH_FQ=y
CONFIG_TCP_CONG_BIC=n
CONFIG_TCP_CONG_WESTWOOD=n
CONFIG_TCP_CONG_HTCP=n
EOF

if [ "${ENABLE_KPM}" = "true" ]; then
  echo "CONFIG_KPM=y" >> "$DEFCONFIG"
fi

sed -i 's/check_defconfig//' ./common/build.config.gki

info "Starting kernel build..."
set -e

export CLANG_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin"
export RUSTC_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/rust/linux-x86/1.73.0b/bin/rustc"
export PAHOLE_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
export PATH="$CLANG_PATH:/usr/lib/ccache:$PATH"

cd $KERNEL_WORKSPACE/kernel_platform/common

make LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" \
  PAHOLE="$PAHOLE_PATH" \
  LD=ld.lld HOSTLD=ld.lld \
  O=out KCFLAGS+=-O2 \
  CONFIG_LTO_CLANG=y CONFIG_LTO_CLANG_THIN=y CONFIG_LTO_CLANG_FULL=n CONFIG_LTO_NONE=n \
  gki_defconfig

make -j$(nproc) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" \
  PAHOLE="$PAHOLE_PATH" \
  LD=ld.lld HOSTLD=ld.lld \
  O=out KCFLAGS+=-O2 Image

if [ "${ENABLE_KPM}" = "true" ]; then
    info "Applying KPM patch..."
    cd out/arch/arm64/boot || error "Failed to enter boot directory"
    curl -LO https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux || error "Failed to download patch_linux"
    chmod +x patch_linux
    ./patch_linux || error "Failed to apply patch_linux"
    rm -f Image
    mv oImage Image || error "Failed to replace Image"
fi

info "Creating AnyKernel3 package..."
cd "$WORKSPACE" || error "Failed to return to workspace"
git clone -q https://github.com/thaihong339/idk.git --depth=1 || info "AnyKernel3 already exists"
rm -rf ./AnyKernel3/.git
rm -f ./AnyKernel3/push.sh
cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" ./AnyKernel3/ || error "Failed to copy Image"

cd AnyKernel3 || error "Failed to enter AnyKernel3 directory"
zip -r "AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_${KERNEL_SUFFIX}_SuKiSu.zip" ./* || error "Packaging failed"

OUTPUT_DIR="C:/Kernel_Build/${DEVICE_NAME}"
mkdir -p "$OUTPUT_DIR" || error "Failed to create output directory"

cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" "$OUTPUT_DIR/"
cp "$WORKSPACE/AnyKernel3/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_${KERNEL_SUFFIX}_SuKiSu.zip" "$OUTPUT_DIR/"

info "Kernel zip path: $OUTPUT_DIR/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_${KERNEL_SUFFIX}_SuKiSu.zip"
info "Image path: $OUTPUT_DIR/Image"
info "Cleaning up all files from this build..."
sudo rm -rf "$WORKSPACE" || error "Failed to delete workspace, maybe not created"
info "Cleanup complete! Next run will re-download source and rebuild kernel."
