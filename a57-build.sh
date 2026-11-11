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

echo "=== 3. Patch SUSFS 4.9 ===" | tee -a build.log
patch -p1 --forward --fuzz=5 < susfs4ksu/kernel_patches/50_add_susfs_in_kernel-4.9.patch 2>&1 | tee -a build.log || echo "Patch SUSFS kernel GAGAL, lanjut manual" | tee -a build.log
patch -p1 --forward --fuzz=5 < susfs4ksu/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch 2>&1 | tee -a build.log || echo "Patch SUSFS KSU GAGAL, lanjut manual" | tee -a build.log
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/ksu.c || true
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/*.c drivers/kernelsu/kernel/*.h 2>/dev/null || true

echo "=== 3c. FIX SUSFS MANUAL - yang bener ===" | tee -a build.log
python3 <<'PYEOF' 2>&1 | tee -a build.log
import pathlib, shutil, glob, os
# Copy semua file susfs yang ada di patch, ke tempat benernya
for src in glob.glob("susfs4ksu/kernel_patches/**/*", recursive=True):
    if os.path.isfile(src):
        dst = src.replace("susfs4ksu/kernel_patches/", "")
        if not os.path.exists(dst):
            os.makedirs(os.path.dirname(dst), exist_ok=True)
            shutil.copy(src, dst)
            print(f"Copy manual: {src} -> {dst}")
# Cek kernel/susfs ada nggak
print(f"kernel/susfs ada? {os.path.exists('kernel/susfs')}")
if os.path.exists('kernel/susfs'):
    print(f"Isi kernel/susfs: {os.listdir('kernel/susfs')}")
# FIX kernel/Makefile: JANGAN nambah susfs/ kalau folder-nya nggak ada
p = pathlib.Path("kernel/Makefile")
t = p.read_text()
if "susfs" in t.lower():
    # hapus baris susfs yang bikin error Build 39
    lines = [l for l in t.splitlines() if "susfs" not in l.lower()]
    p.write_text("\n".join(lines) + "\n")
    print("FIX kernel/Makefile OK - baris susfs yang bikin error dihapus")
else:
    print("kernel/Makefile udah bersih, nggak ada susfs")
# Kalau kernel/susfs beneran ada, baru tambahin lagi
if os.path.exists('kernel/susfs/Makefile'):
    p.write_text(p.read_text() + "\nobj-$(CONFIG_KSU_SUSFS) += susfs/\n")
    print("FIX kernel/Makefile OK - susfs ditambah lagi soalnya folder-nya ada")
# fs/Makefile
p = pathlib.Path("fs/Makefile")
t = p.read_text()
if "susfs" not in t.lower():
    t += "\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n"
    p.write_text(t)
    print("FIX fs/Makefile OK")
else:
    print("fs/Makefile udah ada susfs")
# fs.h
p = pathlib.Path("include/linux/fs.h")
t = p.read_text()
if "susfs" not in t.lower():
    if "#include <linux/dcache.h>" in t:
        t = t.replace("#include <linux/dcache.h>", "#include <linux/dcache.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif")
        print("FIX fs.h OK")
    else:
        t = t.replace("#endif", "#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif\n#endif", 1)
        print("FIX fs.h OK - fallback")
    p.write_text(t)
else:
    print("fs.h udah ada susfs")
# Kconfig SUSFS
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
    print("FIX drivers/kernelsu/Kconfig OK")
else:
    print("drivers/kernelsu/Kconfig udah ada SUSFS")
for kf in ["kernel/Kconfig", "Kconfig"]:
    pp = pathlib.Path(kf)
    if pp.exists():
        tt = pp.read_text()
        if 'drivers/kernelsu/Kconfig' not in tt:
            tt += '\nsource "drivers/kernelsu/Kconfig"\n'
            pp.write_text(tt)
            print(f"FIX {kf} OK - source KSU ditambah")
        else:
            print(f"{kf} udah ada source KSU")
    else:
        print(f"{kf} tidak ada")
PYEOF

echo "=== 3b. Patch MDSS ===" | tee -a build.log
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
grep CONFIG_KSU out/.config | tee -a build.log || echo "CONFIG_KSU TIDAK ADA" | tee -a build.log
grep -c "CONFIG_KSU_SUSFS=y" out/.config | tee -a build.log

echo "=== 5. Build ===" | tee -a build.log
make -j$(nproc --all) O=out ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- 2>&1 | tee -a build.log
ls -lh out/arch/arm64/boot/Image.gz-dtb | tee -a build.log
cp out/arch/arm64/boot/Image.gz-dtb ./Image.gz-dtb 2>/dev/null || cp out/arch/arm64/boot/Image.gz ./Image.gz-dtb 2>/dev/null
echo "BUILD SELESAI" | tee -a build.log
