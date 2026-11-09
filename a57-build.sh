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
ls drivers/kernelsu/ | tee -a build.log

# 3. Config A57
DEFCONFIG=msm8937-perf_defconfig
echo "=== Edit Defconfig $DEFCONFIG ===" | tee -a build.log

sed -i '/CONFIG_KPROBES/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_KALLSYMS/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_KALLSYMS_ALL/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_CC_STACKPROTECTOR_STRONG/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_CC_STACKPROTECTOR/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_MSM_ADRENO_TRACE/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_MSM_ADRENO_TRACING/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_MSM_KGSL_TRACE/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_MSM_KGSL_TRACING/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_TRACING/d' arch/arm64/configs/$DEFCONFIG

echo "CONFIG_KPROBES=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_KALLSYMS=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_KALLSYMS_ALL=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_KSU=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_CC_STACKPROTECTOR_NONE=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_CC_STACKPROTECTOR=n" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_MSM_ADRENO_TRACE=n" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_MSM_ADRENO_TRACING=n" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_MSM_KGSL_TRACE=n" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_MSM_KGSL_TRACING=n" >> arch/arm64/configs/$DEFCONFIG

sed -i '/CONFIG_BT_FM_SLIM/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_BTFM_SLIM/d' arch/arm64/configs/$DEFCONFIG

# 4. FIX BTFM_SLIM
echo "=== Fix BTFM_SLIM ===" | tee -a build.log
git checkout -- drivers/bluetooth/btfm_slim.h || true
rm -f drivers/bluetooth/btfm_slim_stub.c
sed -i '/btfm_slim_stub/d' drivers/bluetooth/Makefile || true
sed -i '/btfm_slim\.o/d' drivers/bluetooth/Makefile || true
sed -i '/btfm_slim/d' drivers/bluetooth/Makefile || true
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

# 5. FIX KGSL / ADRENO TRACE
echo "=== Fix KGSL ===" | tee -a build.log
git checkout -- drivers/gpu/msm/kgsl_trace.h || true
git checkout -- drivers/gpu/msm/adreno_trace.h || true
git checkout -- drivers/gpu/msm/kgsl_trace.c || true
git checkout -- drivers/gpu/msm/adreno_trace.c || true
find drivers/gpu/msm -name "Makefile*" -exec sed -i '/kgsl_trace/d; /adreno_trace/d; /kgsl_events/d' {} \;
grep -q "ccflags-y += -I" drivers/gpu/msm/Makefile || echo 'ccflags-y += -I$(srctree)/drivers/gpu/msm -I$(src)' >> drivers/gpu/msm/Makefile
python3 << 'PYEOF'
import re, glob, os
for f in glob.glob("drivers/gpu/msm/*.c"):
    base = os.path.basename(f)
    if "trace" in base or "events" in base:
        continue
    try:
        t = open(f, errors="ignore").read()
        orig = t
        t = re.sub(r'\btrace_kgsl_[a-z_0-9]+\s*\([^;]*?\);', 'do { } while (0);', t)
        t = re.sub(r'#include\s*<\s*(kgsl_[^>]+)>', r'#include "\1"', t)
        t = re.sub(r'#include\s*<\s*(adreno_[^>]+)>', r'#include "\1"', t)
        t = re.sub(r'#include\s*<\s*(msm_[^>]+)>', r'#include "\1"', t)
        t = re.sub(r'#include\s*<\s*(a6xx_[^>]+)>', r'#include "\1"', t)
        t = re.sub(r'#include\s*<\s*(a5xx_[^>]+)>', r'#include "\1"', t)
        if t != orig:
            open(f, 'w').write(t)
            print(f"patched {f}")
    except Exception as e:
        print(f"skip {f}: {e}")
print("patched kgsl done")
PYEOF

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
export CFLAGS="-I$PWD/drivers/gpu/msm -I$PWD/drivers/gpu/msm/adreno"

# 7. Bersihin + Config
echo "=== Clean + Defconfig ===" | tee -a build.log
make clean 2>&1 | tee -a build.log || true
make mrproper 2>&1 | tee -a build.log || true
make ARCH=arm64 $DEFCONFIG 2>&1 | tee -a build.log

# 7b. PATCH SUKISU BUAT KERNEL 4.9 - TARUH DI SINI! SETELAH MRPROPER! BIAR GAK KE-RESET!
echo "=== Patch SukiSU Kernel 4.9 - Final ===" | tee -a build.log
python3 << 'PYEOF'
import glob, os
for f in glob.glob("drivers/kernelsu/**/*.c", recursive=True) + glob.glob("drivers/kernelsu/**/*.h", recursive=True):
    try:
        t = open(f, errors="ignore").read()
        if "MODULE_IMPORT_NS" not in t:
            continue
        print(f"Patching {f}")
        # 1. Hapus baris MODULE_IMPORT_NS yang asli
        lines = [l for l in t.splitlines() if "MODULE_IMPORT_NS" not in l]
        t2 = "\n".join(lines)
        # 2. Tambahin define di atas biar kalau ada sisa, gak error!
        define = "#ifndef MODULE_IMPORT_NS\n#define MODULE_IMPORT_NS(x)\n#endif\n"
        if "MODULE_IMPORT_NS" not in t2 and "#define MODULE_IMPORT_NS" not in t2:
            # Sisipin setelah include pertama
            if "#include" in t2:
                parts = t2.split("\n", 1)
                t2 = parts[0] + "\n" + define + parts[1] if len(parts) > 1 else define + t2
            else:
                t2 = define + t2
        open(f, 'w').write(t2)
        print(f"patched {f}")
    except Exception as e:
        print(f"skip {f}: {e}")
print("SukiSU 4.9 patch done")
PYEOF
grep -r "MODULE_IMPORT_NS" drivers/kernelsu/ | tee -a build.log || echo "MODULE_IMPORT_NS udah bersih!" | tee -a build.log
grep -n "define MODULE_IMPORT_NS" drivers/kernelsu/ksu.c | tee -a build.log

# 8. BUILD KERNEL
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
