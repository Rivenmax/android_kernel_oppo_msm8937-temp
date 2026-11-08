#!/bin/bash
# Build SukiSU Ultra v3.2.0 buat A57 LOS 19.1 - By Rivenmax
set -x
set -e
echo "=== Mulai Build SukiSU A57 LOS 19.1 ===" | tee build.log
rm -rf drivers/kernelsu
curl -LSs "https://raw.githubusercontent.com/SukiSU-Ultra/SukiSU-Ultra/main/kernel/setup.sh" | bash -s v3.2.0
echo "CEK drivers/kernelsu" | tee -a build.log
ls drivers/kernelsu/ | tee -a build.log
DEFCONFIG=msm8937-perf_defconfig
sed -i '/CONFIG_KPROBES/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_KALLSYMS/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_KALLSYMS_ALL/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_CC_STACKPROTEOR_STRONG/d' arch/arm64/configs/$DEFCONFIG
echo "CONFIG_KPROBES=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_KALLSYMS=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_KALLSYMS_ALL=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_KSU=y" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_CC_STACKPROTEOR_NONE=y" >> arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_BT_FM_SLIM/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_BTFM_SLIM/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_BTFM_SLIM/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_BTFM_SLIM/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_BTFM_SLIM/d' arch/arm64/configs/$DEFCONFIG
sed -i '/CONFIG_BTFM_SLIM/d' arch/arm64/configs/$DEFCONFIG
if [ -f drivers/bluetooth/btfm_slim.h ]; then
  echo "// dummy btfm_slim.h" > drivers/bluetooth/btfm_slim.h
fi
echo "=== Generate kgsl_trace.h stub ===" | tee -a build.log
rm -f drivers/gpu/msm/kgsl_trace.h
sed -i 's/kgsl_trace.c/kgsl_trace.o/' drivers/gpu/msm/Makefile
grep -rho "trace_[a-z_0-9]*" drivers/gpu/msm/ | sort -u > /tmp/traces.txt
cat /tmp/traces.txt | tee -a build.log
echo "#ifndef __KGSL_TRACE_H" > drivers/gpu/msm/kgsl_trace.h
echo "#define __KGSL_TRACE_H" >> drivers/gpu/msm/kgsl_trace.h
echo "// auto-generated stub by Rivenmax" >> drivers/gpu/msm/kgsl_trace.h
while read -r fn; do
  echo "#define $fn(...) do { } while (0)" >> drivers/gpu/msm/kgsl_trace.h
done < /tmp/traces.txt
echo "#endif" >> drivers/gpu/msm/kgsl_trace.h
sed -i '/CONFIG_MSM_KGSL_TRACE/d' arch/arm64/configs/$DEFCONFIG
echo "CONFIG_MSM_KGSL_TRACE=n" >> arch/arm64/configs/$DEFCONFIG
echo "CONFIG_MSM_KGSL_TRACING=n" >> arch/arm64/configs/$DEFCONFIG
export ARCH=arm64
export CROSS_COMPILE=aarch64-linux-android-
export MAKE="make -j$(nproc)"
make ARCH=arm64 $DEFCONFIG 2>&1 | tee -a build.log
make ARCH=arm64 -j$(nproc) Image.gz-dtb 2>&1 | tee -a build.log
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
