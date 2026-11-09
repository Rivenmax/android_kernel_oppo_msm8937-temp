#!/bin/bash
# Build SukiSU Ultra v3.2.0 buat A57 LOS 19.1 - By Rivenmax
set -x
set -e
set -o pipefail

echo "=== Mulai Build SukiSU A57 LOS 19.1 ===" | tee build.log

# 1. Cek Toolchain
echo "=== Cek Toolchain ===" | tee -a build.log
which clang | tee -a build.log
which aarch64-linux-gnu-gcc | tee -a build.log
ls $HOME/proton-clang/bin/ | tee -a build.log

# 2. Setup SukiSU Ultra v3.2.0
echo "=== Setup SukiSU ===" | tee -a build.log
rm -rf drivers/kernelsu
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s v3.2.0
echo "CEK drivers/kernelsu" | tee -a build.log
ls drivers/kernelsu/ | tee -a build.log

# 3. Config A57
DEFCONFIG=msm8937-perf_defconfig
echo "=== Edit Defconfig $DEFCONFIG ===" | tee -a build.log

sed -i '/CONFIG_KPROBES/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_KALLSYMS/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_KALLSYMS_ALL/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_CC_STACKPROTECTOR_STRONG/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_CC_STACKPROTECTOR/d' arch/arm64/configs/$DEFCONFIG

echo "CONFIG_KPROBES=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_KALLSYMS=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_KALLSYMS_ALL=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_KSU=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_CC_STACKPROTECTOR_NONE=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_CC_STACKPROTECTOR=n" >> arch/arm64/configs/$DEFCONFIG

sed -i '/CONFIG_BT_FM_SLIM/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_BTFM_SLIM/d' arch/arm64/configs/$DEFCONFIG

# 4. FIX BTFM_SLIM - CARA BENER!
echo "=== Fix BTFM_SLIM ===" | tee -a build.log
git checkout -- drivers/bluetooth/btfm_slim.h || true
rm -f drivers/bluetooth/btfm_slim_stub.c
sed -i '/btfm_slim_stub/d' drivers/bluetooth/Makefile || true
sed -i '/btfm_slim\.o/d' drivers/bluetooth/Makefile || true
sed -i '/btfm_slim/d' drivers/bluetooth/Makefile || true
cat drivers/bluetooth/Makefile | tee -a build.log
python3 << 'PYEOF'
import re
p = "drivers/bluetooth/bluetooth-power.c"
t = open(p).read()
t = re.sub(r'btfm_slim_hw_init\s*\([^;]*?\)', '0', t)
t = re.sub(r'btfm_slim_hw_deinit\s*\([^;]*?\)', '0', t)
t = re.sub(r'btfm_slim_wakeup\s*\([^;]*?\)', '0', t)
open(p, 'w').write(t)
print("patched bluetooth-power.c")
PYEOF
grep -n "btfm_slim" drivers/bluetooth/bluetooth-power.c | tee -a build.log || echo "btfm_slim call udah ilang" | tee -a build.log

# 5. FIX KGSL_TRACE - CARA BENER! JANGAN STUB HEADER!
echo "=== Fix KGSL_TRACE - Cara Bener ===" | tee -a build.log
# Balikin header asli, hapus stub yang salah
git checkout -- drivers/gpu/msm/kgsl_trace.h || true
rm -f drivers/gpu/msm/kgsl_trace.h.orig
# Hapus kgsl_trace dari build, biar gak di-compile sama sekali
sed -i '/kgsl_trace/d' drivers/gpu/msm/Makefile || true
cat drivers/gpu/msm/Makefile | tee -a build.log
# Patch semua file yang manggil trace_kgsl_... jadi 0 / kosong
python3 << 'PYEOF'
import re, glob, os
for f in glob.glob("drivers/gpu/msm/*.c") + glob.glob("drivers/gpu/msm/*.h"):
    try:
        t = open(f, errors="ignore").read()
        orig = t
        # Ganti trace_kgsl_xxx(...) jadi do {} while (0)
        t = re.sub(r'\btrace_kgsl_[a-z_0-9]+\s*\([^;]*?\);', 'do { } while (0);', t)
        t = re.sub(r'\btrace_[a-z_0-9]+\s*\([^;]*?\);', 'do { } while (0);', t)
        if t != orig:
            open(f, 'w').write(t)
            print(f"patched {f}")
    except Exception as e:
        print(f"skip {f}: {e}")
print("patched kgsl trace calls")
PYEOF

sed -i '/CONFIG_MSM_KGSL_TRACE/d' arch/arm64/configs/$DEFCONFIG
echo "CONFIG_MSM_KGSL_TRACE=n" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_MSM_KGSL_TRACING=n" >> arch/arm64/configs/$DEFCONFIG

# 6. Export Toolchain
export ARCH=arm64
export SUBARCH=arm64
export CC=clang
export LD=ld.lld
export AR=llvm-ar
export NM=llvm-nm
export OBJCOPY=llvm-objcopy
export OBJDUMP=llvm-objdump
export STRIP=llvm-strip
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export CLANG_TRIPLE=aarch64-linux-gnu-
export PATH=$HOME/proton-clang/bin:$PATH

# 7. Bersihin + Config
echo "=== Clean + Defconfig ===" | tee -a build.log
make clean 2>&1 | tee -a build.log || true
make mrproper 2>&1 | tee -a build.log || true
make ARCH=arm64 $DEFCONFIG 2>&1 | tee -a build.log

# 8. BUILD KERNEL - INTINYA!
echo "=== Building Image.gz-dtb ===" | tee -a build.log
make ARCH=arm64 CC=clang CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- CLANG_TRIPLE=aarch64-linux-gnu- -j$(nproc) Image.gz-dtb 2>&1 | tee -a build.log

# 9. Cek Hasil
echo "=== HASIL ===" | tee -a build.log
ls -lh arch/arm64/boot/ | tee -a build.log

if [ ! -f "arch/arm64/boot/Image.gz-dtb" ]; then
  echo "ERROR: Image.gz-dtb GAK KEBUAT! Build GAGAL!" | tee -a build.log
  exit 1
fi

cp arch/arm64/boot/Image.gz-dtb ./Image.gz-dtb
cp arch/arm64/boot/Image.gz-dtb ./Image
ls -lh Image* | tee -a build.log
echo "=== Build selesai! ===" | tee -a build.log
