#!/bin/bash
set -e

# Build Kernel Oppo A57 - LOS 19.1
# Kernel 4.9 Non-GKI + SukiSU-Ultra v3.2.0 MURNI

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

echo "=== 2. Clone SukiSU-Ultra v3.2.0 MURNI ===" | tee -a build.log
git clone --branch v3.2.0 --depth 1 https://github.com/SukiSU-Ultra/SukiSU-Ultra.git drivers/kernelsu
cat drivers/kernelsu/kernel/Makefile | grep -i "VERSION" | head -5 | tee -a build.log || true
echo "SukiSU v3.2.0 terkonfirmasi" | tee -a build.log

echo "=== 3. Patch buat Kernel 4.9 ===" | tee -a build.log

# --- Patch 3A: Shim task_stack.h ---
mkdir -p include/linux/sched
cat > include/linux/sched/task_stack.h <<'EOF'
#ifndef _LINUX_SCHED_TASK_STACK_H
#define _LINUX_SCHED_TASK_STACK_H
#include <linux/sched.h>
#endif
EOF
echo "Patch task_stack.h OK" | tee -a build.log

# --- Patch 3G: Shim sched/task.h (di 4.9 isinya masih di sched.h) ---
cat > include/linux/sched/task.h <<'EOF'
#ifndef _LINUX_SCHED_TASK_H
#define _LINUX_SCHED_TASK_H
#include <linux/sched.h>
#endif
EOF
echo "Patch sched/task.h OK" | tee -a build.log

# --- Patch 3B: Shim set_memory.h (wajib buat < 4.10) ---
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

# --- Patch 3E: Shim compiler_types.h (cuma ada di 4.11+, di 4.9 nggak ada) ---
cat > include/linux/compiler_types.h <<'EOF'
#ifndef _LINUX_COMPILER_TYPES_H
#define _LINUX_COMPILER_TYPES_H
#include <linux/compiler.h>
#endif
EOF
echo "Patch compiler_types.h OK" | tee -a build.log

# --- Patch 3C: Patch throne_tracker.c - STATX cuma ada di 4.11+ ---
python3 <<'PYEOF'
import pathlib
p = pathlib.Path("drivers/kernelsu/kernel/throne_tracker.c")
if p.exists():
    t = p.read_text()
    if "linux/version.h" not in t:
        t = t.replace('#include <linux/fs.h>', "#include <linux/fs.h>\n#include <linux/version.h>", 1)
    old = """err = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);"""
    new = """#if LINUX_VERSION_CODE >= KERNEL_VERSION(4,11,0)
    err = vfs_getattr(&path, &stat, STATX_UID, AT_STATX_SYNC_AS_STAT);
#else
    err = vfs_getattr(&path, &stat);
#endif"""
    if old in t:
        t = t.replace(old, new)
        print("Patch throne_tracker.c OK")
    else:
        print("Patch throne_tracker.c pola tidak ketemu, cek manual")
    p.write_text(t)
else:
    print("throne_tracker.c tidak ketemu, skip")
PYEOF

# --- Patch 3D: Patch sucompat.c ---
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

# --- Patch 3F: Patch core_hook.c - security_add_hooks di 4.9 cuma 2 argumen, bukan 3 ---
python3 <<'PYEOF'
import pathlib
p = pathlib.Path("drivers/kernelsu/kernel/core_hook.c")
if p.exists():
    t = p.read_text()
    old = 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks), "ksu")'
    new = 'security_add_hooks(ksu_hooks, ARRAY_SIZE(ksu_hooks))'
    if old in t:
        t = t.replace(old, new)
        print("Patch core_hook.c OK")
    else:
        print("Patch core_hook.c pola tidak ketemu, cek manual")
    p.write_text(t)
else:
    print("core_hook.c tidak ketemu, skip")
PYEOF

# --- Patch 5: Hapus MODULE_IMPORT_NS, nggak ada di kernel 4.9 ---
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/ksu.c || true
sed -i '/MODULE_IMPORT_NS/d' drivers/kernelsu/kernel/*.c drivers/kernelsu/kernel/*.h 2>/dev/null || true
echo "Patch MODULE_IMPORT_NS OK" | tee -a build.log

echo "=== 4. Enable KSU di defconfig ===" | tee -a build.log
make O=out ARCH=arm64 $DEFCONFIG
scripts/config --file out/.config -e CONFIG_KSU || true
scripts/config --file out/.config -e CONFIG_KSU_KPROBES_HOOK || true
scripts/config --file out/.config -d CONFIG_KSU_SUSFS || true
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
