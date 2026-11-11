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

echo "=== 3c. FIX SUSFS MANUAL ===" | tee -a build.log
python3 <<'PYEOF' 2>&1 | tee -a build.log
import pathlib, shutil, glob, os, re
for src in glob.glob("susfs4ksu/kernel_patches/**/*", recursive=True):
    if os.path.isfile(src):
        dst = src.replace("susfs4ksu/kernel_patches/", "")
        if not os.path.exists(dst):
            d = os.path.dirname(dst)
            if d != "":
                os.makedirs(d, exist_ok=True)
            shutil.copy(src, dst)
            print(f"Copy manual: {src} -> {dst}")
p = pathlib.Path("kernel/Makefile")
t = p.read_text()
if "susfs" in t.lower():
    lines = [l for l in t.splitlines() if "susfs" not in l.lower()]
    p.write_text("\n".join(lines) + "\n")
    print("FIX kernel/Makefile OK")
if os.path.exists('kernel/susfs/Makefile'):
    p.write_text(p.read_text() + "\nobj-$(CONFIG_KSU_SUSFS) += susfs/\n")
    print("FIX kernel/Makefile OK - susfs ditambah lagi")
p = pathlib.Path("fs/Makefile")
t = p.read_text()
if "susfs" not in t.lower():
    t += "\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n"
    p.write_text(t)
    print("FIX fs/Makefile OK")
else:
    print("fs/Makefile udah ada susfs")
p = pathlib.Path("include/linux/fs.h")
t = p.read_text()
t2 = re.sub(r"\n\s*u64 android_kabi_reserved[123];", "", t)
if t2 != t:
    print(f"FIX fs.h - hapus {t.count('android_kabi_reserved') - t2.count('android_kabi_reserved')} baris yang salah tempat")
    t = t2
if "susfs" not in t.lower():
    if "#include <linux/dcache.h>" in t:
        t = t.replace("#include <linux/dcache.h>", "#include <linux/dcache.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif")
        print("FIX fs.h OK - include susfs.h")
    p.write_text(t)
    t = p.read_text()
else:
    print("fs.h udah ada susfs include")
    p.write_text(t)
    t = p.read_text()
for struct_name in ["struct super_block {", "struct inode {"]:
    m = re.search(rf"{re.escape(struct_name)}.*?^}};", t, re.DOTALL | re.MULTILINE)
    if m and "android_kabi_reserved1" not in m.group(0):
        t = t.replace(struct_name, struct_name + "\n#ifdef CONFIG_KSU_SUSFS\n\tu64 android_kabi_reserved1;\n\tu64 android_kabi_reserved2;\n\tu64 android_kabi_reserved3;\n#endif", 1)
        print(f"FIX fs.h OK - android_kabi_reserved ditempel di {struct_name}")
    elif m:
        print(f"FIX fs.h OK - {struct_name} udah ada android_kabi_reserved")
    else:
        print(f"FIX fs.h GAGAL - {struct_name} tidak ketemu")
p.write_text(t)
# --- FIX BARU Build 45: core_hook.h path ---
# Cek di mana core_hook.h beneran ada
for cand in ["drivers/kernelsu/kernel/core_hook.h", "drivers/kernelsu/core_hook.h"]:
    print(f"Cek {cand}: ada={os.path.exists(cand)}")
# Benerin include di fs/susfs.c + include/linux/susfs.h
for f in ["fs/susfs.c", "include/linux/susfs.h", "fs/sus_su.c"]:
    pp = pathlib.Path(f)
    if pp.exists():
        tt = pp.read_text()
        if "drivers/kernelsu/core_hook.h" in tt:
            tt = tt.replace("drivers/kernelsu/core_hook.h", "drivers/kernelsu/kernel/core_hook.h")
            pp.write_text(tt)
            print(f"FIX {f} OK - core_hook.h path dibenerin ke kernel/")
        else:
            print(f"{f}: core_hook.h path udah bener / nggak ada")
# Bikin copy cadangan biar 2-2nya ada
if os.path.exists("drivers/kernelsu/kernel/core_hook.h") and not os.path.exists("drivers/kernelsu/core_hook.h"):
    shutil.copy("drivers/kernelsu/kernel/core_hook.h", "drivers/kernelsu/core_hook.h")
    print("FIX core_hook.h OK - di-copy ke drivers/kernelsu/ juga")
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
