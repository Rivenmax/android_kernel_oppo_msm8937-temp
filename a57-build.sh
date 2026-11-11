#!/bin/bash
set -e
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

echo "=== 1. Bersihin ===" | tee -a build.log
rm -rf drivers/kernelsu susfs4ksu out
mkdir -p out

echo "=== 2. Clone KSU 0.9.5 ===" | tee -a build.log
git clone --branch v0.9.5 --depth 1 https://github.com/tiann/KernelSU.git drivers/kernelsu

echo "=== 2b. Clone SUSFS 1.4.2-kernel-4.9 - TAG BENER ===" | tee -a build.log
git clone --branch 1.4.2-kernel-4.9 https://gitlab.com/simonpunk/susfs4ksu.git susfs4ksu
git -C susfs4ksu log --oneline -1 | tee -a build.log
ls susfs4ksu/kernel_patches/ | tee -a build.log
ls susfs4ksu/kernel_patches/KernelSU/ | tee -a build.log

echo "=== 3. Patch SUSFS 4.9 ===" | tee -a build.log
patch -p1 --forward < susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.9.patch 2>&1 | tee -a build.log || echo "Patch SUSFS kernel GAGAL" | tee -a build.log
patch -p1 --forward < susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch 2>&1 | tee -a build.log || echo "Patch SUSFS KSU GAGAL" | tee -a build.log
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/ksu.c || true
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/*.c drivers/kernelsu/kernel/*.h 2>/dev/null || true

echo "=== 3b. Patch MDSS - cari pola beneran ===" | tee -a build.log
find . -name "mdss_fb.c" 2>/dev/null | tee -a build.log
python3 <<'PYEOF' 2>&1 | tee -a build.log
import pathlib, glob, re
files = glob.glob("drivers/video/**/mdss_fb.c", recursive=True)
print(f"Ketemu {len(files)} file: {files}")
for f in files:
    p = pathlib.Path(f)
    lines = p.read_text().splitlines()
    print(f"--- Isi {f} yang ada kata blank/powerdown ---")
    for i, l in enumerate(lines):
        if "blank" in l.lower() or "BLANK" in l or "powerdown" in l.lower():
            print(f"{i+1}: {l.strip()[:200]}")
    t = p.read_text()
    if "RIVENMAX_FIX_BACKLIGHT" in t:
        print("Patch MDSS udah ada")
        continue
    # Patch generik: cari baris mdss_fb_blank_sub yang ada POWERDOWN, apapun argumennya
    m = re.search(r".*mdss_fb_blank_sub\(FB_BLANK_POWERDOWN.*", t)
    if m:
        old = m.group(0)
        new = "/* RIVENMAX_FIX_BACKLIGHT */\n\t" + old
        t = t.replace(old, new)
        p.write_text(t)
        print(f"Patch MDSS OK di: {old.strip()[:150]}")
    else:
        print("Pola mdss_fb_blank_sub POWERDOWN tidak ketemu, cek print di atas")
PYEOF

echo "=== 4. Enable KSU + SUSFS ===" | tee -a build.log
make O=out ARCH=arm64 $DEFCONFIG
scripts/config --file out/.config -e CONFIG_KSU
scripts/config --file out/.config -e CONFIG_KSU_SUSFS
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_SUS_PATH
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_SUS_MOUNT
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_SUS_KSTAT
scripts/config --file out/.config -e CONFIG_KSU_SUSFS_TRY_UMOUNT
make O=out ARCH=arm64 olddefconfig
echo "--- CEK SUSFS DI CONFIG ---" | tee -a build.log
grep CONFIG_KSU out/.config | tee -a build.log || echo "CONFIG_KSU TIDAK ADA SAMA SEKALI" | tee -a build.log

echo "=== 5. Build ===" | tee -a build.log
make -j$(nproc --all) O=out ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- 2>&1 | tee -a build.log
ls -lh out/arch/arm64/boot/Image.gz-dtb | tee -a build.log
cp out/arch/arm64/boot/Image.gz-dtb ./Image.gz-dtb 2>/dev/null || cp out/arch/arm64/boot/Image.gz ./Image.gz-dtb 2>/dev/null
echo "BUILD SELESAI" | tee -a build.log
