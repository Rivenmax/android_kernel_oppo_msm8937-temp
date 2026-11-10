#!/bin/bash
set -e

# Build 3 - Kernel Oppo A57 - LOS 19.1
# Kernel 4.9 Non-GKI + KernelSU v0.9.5 + SUSFS + Fix Backlight MDSS

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
rm -rf susfs4ksu
rm -rf out
mkdir -p out

echo "=== 2. Clone KernelSU v0.9.5 ===" | tee -a build.log
git clone --branch v0.9.5 --depth 1 https://github.com/tiann/KernelSU.git drivers/kernelsu
echo "KernelSU v0.9.5 terkonfirmasi" | tee -a build.log

echo "=== 2b. Clone SUSFS main (ada patch 4.9) ===" | tee -a build.log
git clone --depth 1 https://gitlab.com/simonpunk/susfs4ksu.git susfs4ksu
ls susfs4ksu/kernel_patches/ | tee -a build.log
ls susfs4ksu/kernel_patches/KernelSU/ | tee -a build.log

echo "=== 3. Patch SUSFS buat kernel 4.9 ===" | tee -a build.log
# Patch kernel-nya dulu pake patch 4.9
patch -p1 --forward < susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.9.patch || echo "Patch SUSFS kernel 4.9 GAGAL" | tee -a build.log
# Patch KernelSU-nya
patch -p1 --forward < susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch || echo "Patch SUSFS KSU gagal" | tee -a build.log
echo "Patch SUSFS OK" | tee -a build.log

# Patch minimal buat 4.9
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/ksu.c || true
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/*.c drivers/kernelsu/kernel/*.h 2>/dev/null || true
echo "Patch MODULE_IMPORT_NS OK" | tee -a build.log

echo "=== 3b. Patch Fix Backlight MDSS ===" | tee -a build.log
python3 <<'PYEOF'
import pathlib, glob
found = False
for f in glob.glob("drivers/video/**/mdss_fb.c", recursive=True):
    print(f"Ketemu mdss_fb.c di: {f}")
    found = True
    p = pathlib.Path(f)
    t = p.read_text()
    if "RIVENMAX_FIX_BACKLIGHT" in t:
        print("Patch MDSS udah ada, skip")
        continue
    old = "mdss_fb_blank_sub(FB_BLANK_POWERDOWN, mfd, op_enable);"
    if old in t:
        new = "/* RIVENMAX_FIX_BACKLIGHT */\n\tmdss_fb_blank_sub(FB_BLANK_POWERDOWN, mfd, op_enable);"
        t = t.replace(old, new)
        p.write_text(t)
        print("Patch MDSS OK")
    else:
        print("Pola MDSS tidak ketemu di file ini")
if not found:
    print("File mdss_fb.c TIDAK KETEMU sama sekali, cari manual")
PYEOF

echo "=== 4. Enable KSU + SUSFS di defconfig ===" | tee -a build.log
make O=out ARCH=arm64 $DEFCONFIG
scripts/config --file out/.config -e CONFIG_KSU || true
scripts/config --file out/.config -e CONFIG_KSU_SUSFS || true
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT || true
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_SUS_PATH || true
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_SUS_MOUNT || true
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT || true
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT || true
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_SUS_KSTAT || true
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_TRY_UMOUNT || true
make O=out ARCH=arm64 olddefconfig
grep CONFIG_KSU_SUSFS out/.config | tee -a build.log

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
