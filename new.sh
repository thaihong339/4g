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
KERNEL_SUFFIX="-android14-TG@qdykernel"
# Force enable KPM and LZ4KD for Ace 5 as per request
ENABLE_KPM=true
ENABLE_LZ4KD=true

# Fixed for Ace 5 as per request
DEVICE_NAME="oneplus_ace5"
REPO_MANIFEST="oneplus_ace5.xml"

# Custom suffix input (optional)
read -p "Enter kernel name modification (can be Chinese or emoji, press Enter for default): " input_suffix
[ -n "$input_suffix" ] && KERNEL_SUFFIX="$input_suffix"

# Environmental variables - distinguish ccache directory by device model
export CCACHE_COMPILERCHECK="%compiler% -dumpmachine; %compiler% -dumpversion"
export CCACHE_NOHASHDIR="true"
export CCACHE_HARDLINK="true"
export CCACHE_DIR="$HOME/.ccache_${DEVICE_NAME}"  # Changed to distinguish by device model
export CCACHE_MAXSIZE="8G"

# ccache initialization flag file also distinguished by device model
CCACHE_INIT_FLAG="$CCACHE_DIR/.ccache_initialized"

# Initialize ccache (only first time)
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
    info "ccache is not installed, skipping initialization"
fi

# Working directory - distinguish by device model
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

# Configure Git (only if not configured)
info "Checking Git configuration..."

GIT_NAME=$(git config --global user.name || echo "")
GIT_EMAIL=$(git config --global user.email || echo "")

if [ -z "$GIT_NAME" ] || [ -z "$GIT_EMAIL" ]; then
    info "Git not configured, setting up..."
    git config --global user.name "Q1udaoyu"
    git config --global user.email "sucisama2888@gmail.com"
else
    info "Git already configured."
fi

# Install repo tool (only first time)
if ! command -v repo >/dev/null 2>&1; then
    info "Installing repo tool..."
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > ~/repo || error "Failed to download repo"
    chmod a+x ~/repo
    sudo mv ~/repo /usr/local/bin/repo || error "Failed to install repo"
else
    info "repo tool already installed, skipping installation"
fi

---

## Source Code Management

# Create source directory
KERNEL_WORKSPACE="$WORKSPACE/kernel_workspace"

mkdir -p "$KERNEL_WORKSPACE" || error "Failed to create kernel_workspace directory"

cd "$KERNEL_WORKSPACE" || error "Failed to enter kernel_workspace directory"

# Initialize source code
info "Initializing repo and syncing source code..."
repo init -u https://github.com/OnePlusOSS/kernel_manifest.git -b refs/heads/oneplus/sm8650 -m "$REPO_MANIFEST" --depth=1 || error "repo initialization failed"
repo --trace sync -c -j$(nproc --all) --no-tags || error "repo sync failed"

---

## Core Build Steps

info "Cleaning dirty blocks and ABI protection..."
# Clean up abi protection
for d in kernel_platform/common kernel_platform/msm-kernel; do
  rm "$d"/android/abi_gki_protected_exports_* 2>/dev/null || echo "No protected exports in $d!"
done
# Remove dirty blocks
for f in kernel_platform/{common,msm-kernel,external/dtc}/scripts/setlocalversion; do
  sed -i 's/ -dirty//g' "$f"
  grep -q 'res=.*s/-dirty' "$f" || sed -i '$i res=$(echo "$res" | sed '\''s/-dirty//g'\'')' "$f"
done
# Modify kernel name
info "Modifying kernel name..."
sed -i '$s|echo "\$res"|echo "$KERNEL_SUFFIX"|' kernel_platform/common/scripts/setlocalversion
sed -i '$s|echo "\$res"|echo "$KERNEL_SUFFIX"|' kernel_platform/msm-kernel/scripts/setlocalversion
sed -i '$s|echo "\$res"|echo "$KERNEL_SUFFIX"|' kernel_platform/external/dtc/scripts/setlocalversion


# Set SukiSU
info "Setting up SukiSU..."
cd kernel_platform || error "Failed to enter kernel_platform"
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s susfs-main
cd KernelSU || error "Failed to enter KernelSU directory"
KSU_VERSION=$(expr $(/usr/bin/git rev-list --count main) "+" 10700)
export KSU_VERSION=$KSU_VERSION
sed -i "s/DKSU_VERSION=12800/DKSU_VERSION=${KSU_VERSION}/" kernel/Makefile || error "Failed to modify KernelSU version"

# Set susfs
info "Setting up susfs..."
cd "$KERNEL_WORKSPACE" || error "Failed to return to working directory"
git clone https://gitlab.com/simonpunk/susfs4ksu.git -b gki-android14-6.1 || info "susfs4ksu already exists or clone failed"
git clone https://github.com/Xiaomichael/kernel_patches.git || info "susfs4ksu already exists or clone failed"
git clone -q https://github.com/SukiSU-Ultra/SukiSU_patch.git || info "SukiSU_patch already exists or clone failed"

cd kernel_platform || error "Failed to enter kernel_platform"
cp ../susfs4ksu/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch ./common/
cp ../kernel_patches/next/syscall_hooks.patch ./common/
cp ../susfs4ksu/kernel_patches/fs/* ./common/fs/
cp ../susfs4ksu/kernel_patches/include/linux/* ./common/include/linux/

# LZ4KD is now always enabled for Ace 5
cp ../kernel_patches/001-lz4.patch ./common/
cp ../kernel_patches/lz4armv8.S ./common/lib
cp ../kernel_patches/002-zstd.patch ./common/

cd "$KERNEL_WORKSPACE/kernel_platform/common" || { error "Failed to enter common directory"; }

patch -p1 < 50_add_susfs_in_gki-android14-6.1.patch || true
cp ../../kernel_patches/69_hide_stuff.patch ./
patch -p1 -F 3 < 69_hide_stuff.patch
patch -p1 -F 3 < syscall_hooks.patch

# LZ4KD patches are now always applied
git apply -p1 < 001-lz4.patch || true
patch -p1 < 002-zstd.patch || true

cd "$KERNEL_WORKSPACE/kernel_platform"
# Add SUSFS configuration
info "Adding SUSFS configuration..."
# Define defconfig path
DEFCONFIG=./common/arch/arm64/configs/gki_defconfig
# Write basic configuration
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

# KPM is now always enabled
echo "CONFIG_KPM=y" >> "$DEFCONFIG"

# Remove check_defconfig (disable sanity check)
sed -i 's/check_defconfig//' ./common/build.config.gki

# Build kernel
info "Starting kernel build..."
#!/bin/bash
set -e

# Set toolchain path
export CLANG_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/clang/host/linux-x86/clang-r487747c/bin"
export RUSTC_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/rust/linux-x86/1.73.0b/bin/rustc"
export PAHOLE_PATH="$KERNEL_WORKSPACE/kernel_platform/prebuilts/kernel-build-tools/linux-x86/bin/pahole"
export PATH="$CLANG_PATH:/usr/lib/ccache:$PATH"

# Enter source directory
cd "$KERNEL_WORKSPACE/kernel_platform/common"

# Configure kernel
make LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" \
  PAHOLE="$PAHOLE_PATH" \
  LD=ld.lld HOSTLD=ld.lld \
  O=out KCFLAGS+=-O2 \
  CONFIG_LTO_CLANG=y CONFIG_LTO_CLANG_THIN=y CONFIG_LTO_CLANG_FULL=n CONFIG_LTO_NONE=n \
  gki_defconfig

# Compile kernel image
make -j$(nproc) LLVM=1 ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- CC=clang \
  RUSTC="$RUSTC_PATH" \
  PAHOLE="$PAHOLE_PATH" \
  LD=ld.lld HOSTLD=ld.lld \
  O=out KCFLAGS+=-O2 Image


# Apply KPM patch (always enabled)
info "Applying KPM patch..."
cd out/arch/arm64/boot || error "Failed to enter boot directory"
curl -LO https://github.com/SukiSU-Ultra/SukiSU_KernelPatch_patch/releases/download/0.12.0/patch_linux || error "Failed to download patch_linux"
chmod +x patch_linux
./patch_linux || error "Failed to apply patch_linux"
rm -f Image
mv oImage Image || error "Failed to replace Image"

# Create AnyKernel3 package
info "Creating AnyKernel3 package..."
cd "$WORKSPACE" || error "Failed to return to working directory"
git clone -q https://github.com/thaihong339/AnyKernel3.git --depth=1 || info "AnyKernel3 already exists"
rm -rf ./AnyKernel3/.git
rm -f ./AnyKernel3/push.sh
cp "$KERNEL_WORKSPACE/kernel_platform/common/out/arch/arm64/boot/Image" ./AnyKernel3/ || error "Failed to copy Image"

# Package
cd AnyKernel3 || error "Failed to enter AnyKernel3 directory"
zip -r "AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" ./* || error "Packaging failed"

# Create output directory for Windows C drive (via WSL)
# Removed Image copy, only AnyKernel3.zip will be copied.
WIN_OUTPUT_DIR="/mnt/c/Kernel_Build/${DEVICE_NAME}/"
mkdir -p "$WIN_OUTPUT_DIR" || error "Failed to create Windows directory, C drive might not be mounted. Will save to Linux directory: $WORKSPACE/AnyKernel3/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip"

cp "$WORKSPACE/AnyKernel3/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip" "$WIN_OUTPUT_DIR/"

info "Kernel package path: C:/Kernel_Build/${DEVICE_NAME}/AnyKernel3_${KSU_VERSION}_${DEVICE_NAME}_SuKiSu.zip"
info "Please find the kernel package in the C drive directory."
info "Cleaning up all files from this build..."
sudo rm -rf "$WORKSPACE" || error "Failed to delete working directory, might not have been created"
info "Cleanup complete! The next time you run the script, it will pull the source code again and build the kernel."
