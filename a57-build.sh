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
if os.path.exists('kernel/susfs/Makefile'):
    p.write_text(p.read_text() + "\nobj-$(CONFIG_KSU_SUSFS) += susfs/\n")
    print("FIX kernel/Makefile OK")
p = pathlib.Path("fs/Makefile")
t = p.read_text()
if "susfs" not in t.lower():
    t += "\nobj-$(CONFIG_KSU_SUSFS) += susfs.o\n"
    p.write_text(t)
    print("FIX fs/Makefile OK")
p = pathlib.Path("include/linux/fs.h")
t = p.read_text()
t2 = re.sub(r"\n\s*u64 android_kabi_reserved[123];", "", t)
if t2 != t:
    t = t2
if "susfs" not in t.lower():
    if "#include <linux/dcache.h>" in t:
        t = t.replace("#include <linux/dcache.h>", "#include <linux/dcache.h>\n#ifdef CONFIG_KSU_SUSFS\n#include <linux/susfs.h>\n#endif")
    p.write_text(t)
    t = p.read_text()
else:
    p.write_text(t)
    t = p.read_text()
for struct_name in ["struct super_block {", "struct inode {"]:
    m = re.search(rf"{re.escape(struct_name)}.*?^}};", t, re.DOTALL | re.MULTILINE)
    if m and "android_kabi_reserved1" not in m.group(0):
        t = t.replace(struct_name, struct_name + "\n#ifdef CONFIG_KSU_SUSFS\n\tu64 android_kabi_reserved1;\n\tu64 android_kabi_reserved2;\n\tu64 android_kabi_reserved3;\n#endif", 1)
        print(f"FIX fs.h OK - {struct_name}")
    elif m:
        print(f"FIX fs.h OK - {struct_name} udah ada")
p.write_text(t)
for f in ["fs/susfs.c", "include/linux/susfs.h"]:
    pp = pathlib.Path(f)
    if pp.exists():
        tt = pp.read_text()
        if "drivers/kernelsu/core_hook.h" in tt:
            tt = tt.replace("drivers/kernelsu/core_hook.h", "drivers/kernelsu/kernel/core_hook.h")
            pp.write_text(tt)
            print(f"FIX {f} OK - core_hook.h")
if os.path.exists("drivers/kernelsu/kernel/core_hook.h") and not os.path.exists("drivers/kernelsu/core_hook.h"):
    shutil.copy("drivers/kernelsu/kernel/core_hook.h", "drivers/kernelsu/core_hook.h")
    print("FIX core_hook.h OK")
p = pathlib.Path("drivers/kernelsu/Kconfig")
t = p.read_text() if p.exists() else ""
if "KSU_SUSFS" not in t:
    t += """
config KSU_SUSFS
    bool "KernelSU SUSFS"
    default y
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
    default n
"""
    p.write_text(t)
    print("FIX Kconfig OK - TRY_UMOUNT n")
else:
    t = re.sub(r"(config KSU_SUSFS_TRY_UMOUNT.*?default\s+)y", r"\1n", t, flags=re.DOTALL)
    p.write_text(t)
    print("FIX Kconfig OK - TRY_UMOUNT n")
for kf in ["kernel/Kconfig", "Kconfig"]:
    pp = pathlib.Path(kf)
    if pp.exists():
        tt = pp.read_text()
        if 'drivers/kernelsu/Kconfig' not in tt:
            tt += '\nsource "drivers/kernelsu/Kconfig"\n'
            pp.write_text(tt)
PYEOF

echo "=== 3b. Patch MDSS BENERAN - bl_level 0 ===" | tee -a build.log
python3 <<'PYEOF' 2>&1 | tee -a build.log
import pathlib, glob, re
# 1. Fix mdss_fb.c - pas POWERDOWN, paksa bl_level = 0
for f in glob.glob("drivers/video/**/mdss_fb.c", recursive=True):
    p = pathlib.Path(f)
    t = p.read_text()
    if "RIVENMAX_FIX_BACKLIGHT_REAL" in t:
        print(f"{f}: udah ada fix beneran")
        continue
    # Cari fungsi mdss_fb_blank_sub, tambahin bl_level = 0 sebelum return POWERDOWN
    if "mdss_fb_blank_sub" in t:
        # Sisipin set bl_level = 0 sebelum mdss_fb_blank_sub POWERDOWN dipanggil
        # Cara aman: ganti baris ret = mdss_fb_blank_sub(FB_BLANK_POWERDOWN... dengan set bl_level dulu
        old = "ret = mdss_fb_blank_sub(FB_BLANK_POWERDOWN"
        if old in t:
            new = "/* RIVENMAX_FIX_BACKLIGHT_REAL - paksa bl_level 0 pas blank */\n\tif (mfd) mfd->bl_level = 0;\n\t" + old
            t = t.replace(old, new)
            p.write_text(t)
            print(f"FIX MDSS REAL OK di {f} - bl_level = 0 pas POWERDOWN")
        else:
            print(f"{f}: pola POWERDOWN tidak ketemu")
    else:
        print(f"{f}: mdss_fb_blank_sub tidak ketemu")
# 2. Fix mdss_dsi_panel.c - bl_min dari 1 jadi 0, biar bisa ke 0
for f in glob.glob("drivers/video/**/mdss_dsi_panel.c", recursive=True):
    p = pathlib.Path(f)
    t = p.read_text()
    orig = t
    # Cari bl_min = 1, ubah jadi 0
    t = re.sub(r"bl_min\s*=\s*1", "bl_min = 0", t)
    t = re.sub(r"\.bl_min\s*=\s*1", ".bl_min = 0", t)
    if t != orig:
        p.write_text(t)
        print(f"FIX MDSS PANEL OK di {f} - bl_min 1 -> 0")
    else:
        print(f"{f}: bl_min tidak ketemu / udah 0")
# 3. Fix mdss_fb.c - bl_level minimum check, kalau ada 'if (bl_level < 1) bl_level = 1' ubah jadi 0
for f in glob.glob("drivers/video/**/mdss_fb.c", recursive=True):
    p = pathlib.Path(f)
    t = p.read_text()
    orig = t
    t = re.sub(r"if\s*\(\s*bl_level\s*<\s*1\s*\)\s*bl_level\s*=\s*1", "if (bl_level < 0) bl_level = 0", t)
    t = re.sub(r"bl_level\s*=\s*max\(bl_level,\s*1\)", "bl_level = max(bl_level, 0)", t)
    if t != orig:
        p.write_text(t)
        print(f"FIX MDSS BL_MIN OK di {f} - bl_level min 1 -> 0")
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
scripts/config --file out/.config -d CONFIG_KSU_SUSFS_TRY_UMOUNT
make O=out ARCH=arm64 olddefconfig
echo "--- CEK SUSFS DI CONFIG ---" | tee -a build.log
grep CONFIG_KSU out/.config | tee -a build.log
grep -c "CONFIG_KSU_SUSFS=y" out/.config | tee -a build.log

echo "=== 5. Build ===" | tee -a build.log
make -j$(nproc --all) O=out ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- 2>&1 | tee -a build.log
ls -lh out/arch/arm64/boot/Image.gz-dtb | tee -a build.log
cp out/arch/arm64/boot/Image.gz-dtb ./Image.gz-dtb 2>/dev/null || cp out/arch/arm64/boot/Image.gz ./Image.gz-dtb 2>/dev/null
echo "BUILD SELESAI" | tee -a build.log
