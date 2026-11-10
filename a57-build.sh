#!/bin/bash
set -e

# Build Kernel Oppo A57 - LOS 19.1
# Kernel 4.9 Non-GKI + KernelSU v0.9.5 (paling cocok buat 4.9 + Android 12)

export KERNEL_DIR=$PWD
export ARCH=arm64
export SUBARCH=arm64

DEFCONFIG="lineageos_A57_defconfig"

export PATH="$HOME/proton-clang/bin:$PATH"
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip

touch build.log
echo "=== 1. Bersihin sisa build lama ===" | tee -a build.log
rm -rf drivers/kernelsu
rm -rf out
mkdir -p out

echo "=== 2. Clone KernelSU v0.9.5 ===" | tee -a build.log
git clone --branch v0.9.5 --depth 1 https://github.com/tiann/KernelSU.git drivers/kernelsu
echo "KernelSU v0.9.5 terkonfirmasi" | tee -a build.log

echo "=== 3. Patch minimal buat 4.9 ===" | tee -a build.log
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/ksu.c || true
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/*.c drivers/kernelsu/kernel/*.h 2>/dev/null || true
echo "Patch MODULE_IMPORT_NS OK" | tee -a build.log

echo "=== 4. Enable KSU di defconfig ===" | tee -a build.log
make O=out ARCH=arm64 $DEFCONFIG
scripts/config --file out/.config -e CONFIG_KSU || true
make O=out ARCH=arm64 olddefconfig

echo "=== 5. Build ===" | tee -a build.log
make -j$(nproc --all) O=out ARCH=arm64 \
  CC=clang \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  2>&1 | tee -a build.log

echo "=== 6. Cek hasil ===" | tee -a build.log
ls -lh out/arch/arm64/boot/Image.gz-dtb | tee -a build.log
ls -lh out/arch/arm64/boot/Image* | tee -a build.log
cp out/arch/arm64/boot/Image.gz-dtb ./Image.gz-dtb 2>/dev/null || cp out/arch/arm64/boot/Image.gz ./Image.gz-dtb 2>/dev/null
echo "BUILD SELESAI" | tee -a build.log
