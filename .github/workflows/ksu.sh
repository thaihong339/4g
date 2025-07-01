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
ENABLE_KPM=true
ENABLE_LZ4KD=true
DEVICE_NAME="oneplus_ace5"
REPO_MANIFEST="oneplus_ace5.xml"

# Environment variables - separate ccache directory by device
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
        info "ccache already initialized"
    fi
else
    info "ccache not installed"
fi

WORKSPACE="$GITHUB_WORKSPACE/kernel_${DEVICE_NAME}"
mkdir -p "$WORKSPACE" || error "Failed to create working directory"
cd "$WORKSPACE" || error "Failed to enter working directory"

info "Checking and installing dependencies..."
DEPS=(python3 git curl ccache flex bison libssl-dev libelf-dev bc zip)
MISSING_DEPS=()
for pkg in "${DEPS[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
        MISSING_DEPS+=("$pkg")
    fi
done
if [ ${#MISSING_DEPS[@]} -gt 0 ]; then
    apt-get update || error "System update failed"
    apt-get install -y "${MISSING_DEPS[@]}" || error "Dependency install failed"
fi

info "Checking Git config..."
GIT_NAME=$(git config --global user.name || echo "")
GIT_EMAIL=$(git config --global user.email || echo "")
if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
    git config --global user.name "Builder"
    git config --global user.email "builder@example.com"
fi

if ! command -v repo >/dev/null 2>&1; then
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > ~/repo || error "Failed to download repo"
    chmod a+x ~/repo && mv ~/repo /usr/local/bin/repo || error "Failed to install repo"
fi

KERNEL_WORKSPACE="$WORKSPACE/kernel_workspace"
mkdir -p "$KERNEL_WORKSPACE" && cd "$KERNEL_WORKSPACE" || error "Workspace failed"
repo init -u https://github.com/OnePlusOSS/kernel_manifest.git -b refs/heads/oneplus/sm8650 -m "$REPO_MANIFEST" --depth=1 || error "Repo init failed"
repo --trace sync -c -j$(nproc) --no-tags || error "Repo sync failed"

info "Cleaning dirty tags and ABI protections..."
for d in kernel_platform/common kernel_platform/msm-kernel; do
  rm "$d"/android/abi_gki_protected_exports_* 2>/dev/null || true
done
for f in kernel_platform/{common,msm-kernel,external/dtc}/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  grep -q 'res=.*s/-dirty' "$f" || sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
done

info "Setting up SukiSU..."
cd kernel_platform || error "Failed to enter kernel_platform"
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-main
cd KernelSU || error "Failed to enter KernelSU"
KSU_VERSION=$(expr $(/usr/bin/git rev-list --count main) + 10700)
export KSU_VERSION=$KSU_VERSION
sed -i "s/DKSU_VERSION=12800/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile || error "KernelSU version patch failed"

info "Setting dynamic kernel version string..."
for f in ../{common,msm-kernel,external/dtc}/scripts/setlocalversion; do
  sed -i "\$s|echo \"\$res\"|echo \"-android14-${KSU_VERSION}\"|" "$f"
done

cd "$KERNEL_WORKSPACE" || error "Back to workspace failed"
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android14-6.1 || true
git clone https://github.com/Xiaomichael/kernel_patches.git || true
git clone -q https://github.com/SukiSU-Ultra/SukiSU_patch.git || true

cd kernel_platform || error "Re-enter kernel_platform"
cp ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./common/
cp ../kernel_patches/next/syscall_hooks.patch ./common/
cp ../susfs4ksu/kernel_patches/fs/* ./common/fs/
cp ../susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/
cp ../kernel_patches/001-lz4.patch ./common/
cp ../kernel_patches/lz4armv8.S ./common/lib
cp ../kernel_patches/002-zstd.patch ./common/

cd common || error "Failed to enter common"
patch -p1 < 50_add_susfs_in_gki-android14-6.1.patch || true
cp ../../kernel_patches/69_hide_stuff.patch ./ && patch -p1 -F 3 < 69_hide_stuff.patch
patch -p1 -F 3 < syscall_hooks.patch
git apply -p1 < 001-lz4.patch || true
patch -p1 < 002-zstd.patch || true

info "Adding SUSFS config..."
DEFCONFIG=./arch/arm64/configs/gki_defconfig
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

[ "$ENABLE_KPM" = "true" ] && echo "CONFIG_KPM=y" >> "$DEFCONFIG"
sed -i 's/check_defconfig//' ./build.config.gki

info "Starting kernel build..."
export CLANG_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin"
export RUSTC_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/rust/linux-x86/1.73.0b/bin/rustc"
export PAHOLE_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
export PATH="$CLANG_PATH:/usr/lib/ccache:$PATH"

cd common
make LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" PAHOLE="$PAHOLE_PATH" LD=ld.lld HOSTLD=ld.lld \
  O=out KCFLAGS+=-O2 CONFIG_LTO_CLANG=y CONFIG_LTO_CLANG_THIN=y gki_defconfig

make -j$(nproc) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" PAHOLE="$PAHOLE_PATH" LD=ld.lld HOSTLD=ld.lld \
  O=out KCFLAGS+=-O2 Image

if [ "$ENABLE_KPM" = "true" ]; then
    info "Applying KPM patch..."
    cd out/arch/arm64/boot || error "Failed to enter boot"
    curl -LO https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux
    chmod +x patch_linux && ./patch_linux || error "patch_linux failed"
    rm -f Image && mv oImage Image || error "Replace Image failed"
fi

info "Creating AnyKernel3 package..."
cd "$WORKSPACE" && git clone -q https://github.com/thaihong339/AnyKernel3.git --depth=1 || true
rm -rf ./AnyKernel3/.git ./AnyKernel3/push.sh
cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" ./AnyKernel3/

cd AnyKernel3 && zip -r "AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" ./* || error "Zip failed"

OUTPUT_DIR="${GITHUB_WORKSPACE:-$PWD}/output"
mkdir -p "$OUTPUT_DIR"
cp "$WORKSPACE/AnyKernel3/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" "$OUTPUT_DIR/"
cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" "$OUTPUT_DIR/"

info "Kernel package: $OUTPUT_DIR/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip"
info "Image: $OUTPUT_DIR/Image"
info "Build complete."
