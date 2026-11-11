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

echo "=== 2b. Clone SUSFS 1.4.2-kernel-4.9 ===" | tee -a build.log
git clone --branch 1.4.2-kernel-4.9 https://gitlab.com/simonpunk/susfs4ksu.git susfs4ksu
git -C susfs4ksu log --oneline -1 | tee -a build.log
ls susfs4ksu/kernel_patches/ | tee -a build.log
ls susfs4ksu/kernel_patches/KernelSU/ | tee -a build.log

echo "=== 3. Patch SUSFS 4.9 - pake fuzz biar nggak FAILED ===" | tee -a build.log
patch -p1 --forward --fuzz=5 < susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.9.patch 2>&1 | tee -a build.log || echo "Patch SUSFS kernel GAGAL, lanjut manual" | tee -a build.log
patch -p1 --forward --fuzz=5 < susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch 2>&1 | tee -a build.log || echo "Patch SUSFS KSU GAGAL, lanjut manual" | tee -a build.log
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/ksu.c || true
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/*.c drivers/kernelsu/kernel/*.h 2>/dev/null || true

echo "=== 3c. FIX SUSFS MANUAL - Kconfig + Makefile + fs.h ===" | tee -a build.log
python3 <<'PYEOF' 2>&1 | tee -a build.log
import pathlib

# --- 1. Copy file susfs yang belum ke-copy dari patch ---
import shutil, glob, os
for src in glob.glob("susfs4ksu/kernel_patches/fs/susfs*") + glob.glob("susfs4ksu/kernel_patches/include/linux/susfs*"):
    dst = src.replace("susfs4ksu/kernel_patches/", "")
    if os.path.exists(src) and not os.path.exists(dst):
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        shutil.copy(src, dst)
        print(f"Copy manual: {src} -> {dst}")
for src in glob.glob("susfs4ksu/kernel_patches/fs/*.c") + glob.glob("susfs4ksu/kernel_patches/fs/*.h"):
    dst = src.replace("susfs4ksu/kernel_patches/", "")
    if os.path.exists(src) and not os.path.exists(dst):
        shutil.copy(src, dst)
        print(f"Copy manual fs: {dst}")

# --- 2. kernel/Makefile : pastiin ada obj susfs ---
p = pathlib.Path("kernel/Makefile")
t = p.read_text()
if "susfs" not in t.lower():
    t += "\nobj-$(CONFIG_KSU_SUSFS) += susfs/\n"
    p.write_text(t)
    print("FIX kernel/Makefile OK - ditambah obj susfs")
else:
    print("kernel/Makefile udah ada susfs")

# --- 3. fs/Makefile : pastiin ada susfs ---
p = pathlib.Path("fs/Makefile")
t = p.read_text()
if "susfs" not in t.lower():
    t += "\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n"
    p.write_text(t)
    print("FIX fs/Makefile OK")
else:
    print("fs/Makefile udah ada susfs")

# --- 4. include/linux/fs.h : pastiin ada susfs include ---
p = pathlib.Path("include/linux/fs.h")
t = p.read_text()
if "susfs" not in t.lower():
    # tempel di bawah #include <linux/dcache.h> atau di atas #endif terakhir
    if "#include <linux/dcache.h>" in t:
        t = t.replace("#include <linux/dcache.h>", "#include <linux/dcache.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif")
        print("FIX fs.h OK - include susfs.h ditambah")
    else:
        t = t.replace("#endif", "#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif\n#endif", 1)
        print("FIX fs.h OK - fallback")
    p.write_text(t)
else:
    print("fs.h udah ada susfs")

# --- 5. drivers/kernelsu/Kconfig : tempel Kconfig SUSFS kalau belum ada ---
p = pathlib.Path("drivers/kernelsu/Kconfig")
t = p.read_text() if p.exists() else ""
if "KSU_SUSFS" not in t:
    susfs_kconfig = """
config KSU_SUSFS
    bool "KernelSU SUSFS"
    default y
    help
      Enable SUSFS for KernelSU

config KSU_SUSFS_HAS_MAGIC_MOUNT
    bool "SUSFS Magic Mount"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_PATH
    bool "SUSFS SUS_PATH"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_MOUNT
    bool "SUSFS SUS_MOUNT"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT
    bool "SUSFS Auto Add KSU Default Mount"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_AUTO_ADD_SUS_BIND_MOUNT
    bool "SUSFS Auto Add Bind Mount"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_SUS_KSTAT
    bool "SUSFS SUS_KSTAT"
    depends on KSU_SUSFS
    default y

config KSU_SUSFS_TRY_UMOUNT
    bool "SUSFS Try Umount"
    depends on KSU_SUSFS
    default y
"""
    p.write_text(t + susfs_kconfig)
    print("FIX drivers/kernelsu/Kconfig OK - SUSFS Kconfig ditempel")
else:
    print("drivers/kernelsu/Kconfig udah ada SUSFS")

# --- 6. kernel/Kconfig : pastiin source KSU masuk ---
p = pathlib.Path("kernel/Kconfig")
if p.exists():
    t = p.read_text()
    if 'drivers/kernelsu/Kconfig' not in t and 'kernelsu' not in t.lower():
        t += '\nsource "drivers/kernelsu/Kconfig"\n'
        p.write_text(t)
        print("FIX kernel/Kconfig OK - source KSU ditambah")
    else:
        print("kernel/Kconfig udah ada source KSU")
PYEOF

echo "=== 3b. Patch MDSS - yang udah berhasil ===" | tee -a build.log
find . -name "mdss_fb.c" 2>/dev/null | tee -a build.log
python3 <<'PYEOF' 2>&1 | tee -a build.log
import pathlib, glob, re
files = glob.glob("drivers/video/**/mdss_fb.c", recursive=True)
print(f"Ketemu {len(files)} file: {files}")
for f in files:
    p = pathlib.Path(f)
    t = p.read_text()
    if "RIVENMAX_FIX_BACKLIGHT" in t:
        print("Patch MDSS udah ada")
        continue
    m = re.search(r".*mdss_fb_blank_sub\(FB_BLANK_POWERDOWN.*", t)
    if m:
        old = m.group(0)
        new = "/* RIVENMAX_FIX_BACKLIGHT */\n\t" + old
        t = t.replace(old, new)
        p.write_text(t)
        print(f"Patch MDSS OK di: {old.strip()[:150]}")
    else:
        print("Pola MDSS tidak ketemu")
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
grep -c "CONFIG_KSU_SUSFS=y" out/.config | tee -a build.log

echo "=== 5. Build ===" | tee -a build.log
make -j$(nproc --all) O=out ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- 2>&1 | tee -a build.log
ls -lh out/arch/arm64/boot/Image.gz-dtb | tee -a build.log
cp out/arch/arm64/boot/Image.gz-dtb ./Image.gz-dtb 2>/dev/null || cp out/arch/arm64/boot/Image.gz ./Image.gz-dtb 2>/dev/null
echo "BUILD SELESAI" | tee -a build.log
