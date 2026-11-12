#!/bin/bash
set -e
echo "=== RIVENMAX Build 48 - KSU + SUSFS + DSI PANEL bl 0 ==="

# 1. ENV
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER=RIVENMAX
export KBUILD_BUILD_HOST=RIVENMAX-A57
export PATH=$GITHUB_WORKSPACE/proton-clang/bin:$PATH
export CC=clang
export CLANG_TRIPLE=aarch64-linux-gnu-
export CROSS_COMPILE=aarch64-linux-gnu-
export CROSS_COMPILE_ARM32=arm-linux-gnueabi-
export LLVM=1
export LLVM_IAS=1

# 2. CLANG
if [ ! -d proton-clang ]; then
  git clone --depth=1 https://github.com/kdrag0n/proton-clang.git proton-clang
fi

# 3. KSU
if [ ! -d KernelSU ]; then
  git clone --depth=1 https://github.com/tiann/KernelSU.git KernelSU
fi

# 3a. Patch SUSFS - FIX GITLAB TANPA -b
echo "=== 3a. Patch SUSFS ==="
if [ ! -d susfs4ksu ]; then
  git clone --depth=1 https://gitlab.com/simonpunk/susfs4ksu.git susfs4ksu
fi
ls susfs4ksu/kernel_patches/ || true
find susfs4ksu -name "*.patch" | head -n 20 || true
cp -r susfs4ksu/kernel_patches/fs/* fs/ 2>/dev/null || true
cp -r susfs4ksu/kernel_patches/include/* include/ 2>/dev/null || true
PATCH_FILE=$(find susfs4ksu -name "*susfs*.patch" | head -n 1)
echo "PATCH_FILE=$PATCH_FILE"
if [ -n "$PATCH_FILE" ]; then
  patch -p1 --forward < "$PATCH_FILE" 2>/dev/null || echo "SUSFS patch udah / skip"
fi

# 3d. Setup KernelSU - INI YANG KEMARIN KELEWAT
echo "=== 3d. Setup KernelSU ==="
ls KernelSU/kernel/setup.sh || true
if [ -f KernelSU/kernel/setup.sh ]; then
  bash KernelSU/kernel/setup.sh
fi
ls -lh drivers/kernelsu/kernel/Kconfig || true

# 3b. Patch DSI PANEL Build 48 - INI YANG BENERIN BACKLIGHT
echo "=== 3b. Patch DSI PANEL Build 48 - bl 0 via DCS ==="
python3 - << 'PY'
import pathlib, re
p = pathlib.Path("drivers/video/fbdev/msm/mdss_dsi_panel.c")
t = p.read_text()
print("sebelum patch, ada bl_min?", "bl_min" in t)
t = t.replace("bl_level = 1;", "bl_level = 0; // RIVENMAX_48")
t = t.replace("max(bl_level, 1)", "max(bl_level, 0) // RIVENMAX_48")
t = t.replace("bl_level < 1", "bl_level < 0 // RIVENMAX_48")
t = re.sub(r"if\s*\(\s*bl_level\s*==\s*0\s*\)\s*bl_level\s*=\s*1\s*;", "/* RIVENMAX_48 allow bl 0 */", t)
p.write_text(t)
print("FIX DSI PANEL OK - clamp 1 -> 0, allow DCS 0")
PY
sed -i 's/qcom,mdss-dsi-bl-min-level = <1>/qcom,mdss-dsi-bl-min-level = <0> \/\/ RIVENMAX_48/g' arch/arm/boot/dts/qcom/*.dtsi 2>/dev/null || true
sed -i 's/qcom,mdss-dsi-bl-min-level = <0x1>/qcom,mdss-dsi-bl-min-level = <0x0> \/\/ RIVENMAX_48/g' arch/arm/boot/dts/qcom/*.dtsi 2>/dev/null || true
echo "FIX DTB BL_MIN OK"

# 3c. MDSS FB tetap
echo "=== 3c. Patch MDSS FB tetap ==="
sed -i 's/bl_level = 1;/bl_level = 0; \/\/ RIVENMAX_FIX_48/g' drivers/video/fbdev/msm/mdss_fb.c 2>/dev/null || true
echo "FIX MDSS FB OK"

# 4. DEFCONFIG
echo "=== 4. Defconfig ==="
make O=out ARCH=arm64 lineageos_A57_defconfig

# 5. KSU + SUSFS config - SAMA KAYAK BUILD 46/47 YANG BOOT
echo "=== 5. Config KSU SUSFS ==="
scripts/config --file out/.config -e KSU -e KSU_SUSFS -e KSU_SUSFS_HAS_MAGIC_MOUNT -e KSU_SUSFS_SUS_PATH -e KSU_SUSFS_SUS_MOUNT -e KSU_SUSFS_AUTO_ADD_SUS_KSU_DEFAULT_MOUNT -e KSU_SUSFS_SUS_KSTAT -e KSU_SUSFS_TRY_UMOUNT 2>/dev/null || true
scripts/config --file out/.config -d KSU_SUSFS_TRY_UMOUNT 2>/dev/null || true
scripts/config --file out/.config -d KSU_SUSFS_SUS_MAP 2>/dev/null || true
make O=out ARCH=arm64 olddefconfig
grep -E "CONFIG_KSU_SUSFS=y|CONFIG_KSU_SUSFS_HAS_MAGIC_MOUNT" out/.config || true
grep "CONFIG_KSU_SUSFS_TRY_UMOUNT" out/.config || true

# 6. BUILD
echo "=== 6. Build Kernel ==="
make -j$(nproc) O=out ARCH=arm64 CC=clang CLANG_TRIPLE=aarch64-linux-gnu- CROSS_COMPILE=aarch64-linux-gnu- CROSS_COMPILE_ARM32=arm-linux-gnueabi- LLVM=1 LLVM_IAS=1 Image.gz-dtb 2>&1 | tee build.log

# 7. CEK
echo "=== 7. Cek Hasil ==="
ls -lh out/arch/arm64/boot/Image.gz-dtb
grep -E "FIX DSI PANEL|FIX DTB|FIX MDSS FB|CONFIG_KSU_SUSFS" build.log | head -n 30 || true
echo "BUILD SELESAI"
