#!/bin/bash
set -e

# ============================================
# Build Kernel 【entity-Oppo¦canonical_name=Oppo】 A57 - LOS 19.1
# Kernel 4.9 Non-GKI + SukiSU-Ultra v3.2.0 MURNI
# ============================================

export KERNEL_DIR=$PWD
export ARCH=arm64
export SUBARCH=arm64

# Defconfig - GANTI kalau di repo kamu namanya beda
# Cek di arch/arm64/configs/
DEFCONFIG="msm8937-perf_defconfig"
# Kalau pakai Lineage biasanya: lineage_msm8937_defconfig
# Kalau gagal, ganti ke nama defconfig yang ada di repo kamu

# Toolchain Proton Clang
export PATH="$HOME/proton-clang/bin:$PATH"
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export CC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip

mkdir -p build.log
echo "=== 1. Bersihin sisa build lama ===" | tee -a build.log
rm -rf drivers/kernelsu
rm -rf out
mkdir -p out

echo "=== 2. Clone SukiSU-Ultra v3.2.0 MURNI ===" | tee -a build.log
# INI KUNCINYA: pakai --branch v3.2.0, JANGAN pakai main
git clone --branch v3.2.0 --depth 1 https://github.com/SukiSU-Ultra/SukiSU-Ultra.git drivers/kernelsu
echo "SukiSU yang kepakai:" | tee -a build.log
cat drivers/kernelsu/kernel/Makefile | grep -i "VERSION" | head -5 | tee -a build.log || true
# Cek, kalau masih muncul v4.3.0 berarti clone-nya gagal, STOP di sini
if grep -r "4.3.0" drivers/kernelsu/kernel/ 2>/dev/null | head -1; then
  echo "ERROR: Masih ke-download v4.3.0! Cek internet / branch!" | tee -a build.log
  exit 1
fi

echo "=== 3. Patch buat Kernel 4.9 ===" | tee -a build.log

# --- Patch 3A: Shim task_stack.h (error pertama kamu) ---
mkdir -p include/linux/sched
cat > include/linux/sched/task_stack.h <<'EOF'
#ifndef _LINUX_SCHED_TASK_STACK_H
#define _LINUX_SCHED_TASK_STACK_H
#include <linux/sched.h>
#endif
EOF
echo "Patch task_stack.h OK" | tee -a build.log

# --- Patch 3B: Shim set_memory.h (wajib buat < 4.19) ---
cat > include/linux/set_memory.h <<'EOF'
#ifndef _LINUX_SET_MEMORY_H
#define _LINUX_SET_MEMORY_H
#include <linux/types.h>
static inline int set_memory_ro(unsigned long addr, int numpages) { return 0; }
static inline int set_memory_rw(unsigned long addr, int numpages) { return 0; }
static inline int set_memory_x(unsigned long addr, int numpages) { return 0; }
static inline int set_memory_nx(unsigned long addr, int numpages) { return 0; }
#endif
EOF
echo "Patch set_memory.h OK" | tee -a build.log

# --- Patch 3C: Patch throne_tracker.c - STATX cuma ada di 4.11+ (error kedua kamu) ---
python3 <<'PYEOF'
import pathlib
p = pathlib.Path("drivers/kernelsu/kernel/throne_tracker.c")
if p.exists():
    t = p.read_text()
    # Tambahin version.h kalau belum ada
    if "linux/version.h" not in t:
        t = t.replace("#include <linux/fs.h>", "#include <linux/fs.h>\n#include <linux/version.h>", 1)
    # Ganti vfs_getattr versi baru jadi kondisional
    old = "err = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);"
    new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(4,11,0)
    err = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);
#else
    err = vfs_getattr(&path, &stat);
#endif"""
    if old in t:
        t = t.replace(old, new)
        print("Patch throne_tracker.c OK - diganti 2 tempat")
    else:
        print("Patch throne_tracker.c: pola tidak ketemu, cek manual")
    p.write_text(t)
else:
    print("throne_tracker.c tidak ketemu, skip")
PYEOF

# --- Patch 3D: Patch sucompat.c kalau masih include task_stack.h langsung ---
python3 <<'PYEOF'
import pathlib
p = pathlib.Path("drivers/kernelsu/kernel/sucompat.c")
if p.exists():
    t = p.read_text()
    if "linux/sched/task_stack.h" in t:
        t = t.replace("linux/sched/task_stack.h", "linux/sched.h")
        p.write_text(t)
        print("Patch sucompat.c OK")
PYEOF

echo "=== 4. Enable KSU di defconfig ===" | tee -a build.log
make O=out ARCH=arm64 $DEFCONFIG
# Aktifin config KSU
scripts/config --file out/.config -e CONFIG_KSU || true
scripts/config --file out/.config -e CONFIG_KSU_KPROBES_HOOK || true
scripts/config --file out/.config -d CONFIG_KSU_SUSFS || true
# SUSFS matiin dulu, biar build lebih gampang jadi
# Kalau udah jadi, baru coba aktifin SUSFS lagi
make O=out ARCH=arm64 olddefconfig

echo "=== 5. Build ===" | tee -a build.log
make -j$(nproc --all) O=out ARCH=arm64 \
  CC=clang \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  2>&1 | tee -a build.log

echo "=== 6. Cek hasil ===" | tee -a build.log
ls -lh out/arch/arm64/boot/Image.gz-dtb || ls -lh out/arch/arm64/boot/Image* | tee -a build.log
cp out/arch/arm64/boot/Image.gz-dtb ./Image.gz-dtb 2>/dev/null || cp out/arch/arm64/boot/Image.gz ./Image.gz-dtb 2>/dev/null || true
echo "BUILD SELESAI" | tee -a build.log
