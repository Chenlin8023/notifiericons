#!/bin/bash
# =============================================================================
#  NotifierIcons rootless 构建脚本（在 WSL / Linux 下运行）
#
#    wsl -d Ubuntu-22.04 -- bash /mnt/d/WorkBudy/Bioprotect/NotifierIcons/build.sh
#
#  流程与 LSTimeSeconds-rootless-5 完全一致：
#    1. Windows 源目录拷到 WSL 本地（CRLF → LF）
#    2. make package（clang 19 + ld64 956，arm64 + arm64e，rootless /var/jb）
#    3. dpkg-deb -R 解包
#    4. 对 dylib 和设置面板两个 arm64e 二进制做 PAC 补丁
#       （__cfstring isa + __objc_data isa/superclass 认证，tools/patch_arm64e.py）
#    5. ldid 重签、权限归一
#    6. dpkg-deb -b 打包回 Windows 目录
# =============================================================================
set -u

export THEOS="$HOME/theos"
export PATH="$THEOS/bin:$PATH"

SRC=/mnt/d/WorkBudy/Bioprotect/NotifierIcons
DST="$HOME/notifiericons_build"
TC19="$HOME/tc19/linux/iphone/bin"
VERSION="0.9.2"
PKGID="com.chenlin8023.notifiericons"

die() { echo "!! $*"; exit 1; }
[ -x "$TC19/clang" ] || die "clang 19 工具链不存在（$TC19/clang）"

rm -rf "$DST"; mkdir -p "$DST"
cp -r "$SRC"/. "$DST"/
rm -rf "$DST/.git" "$DST/packages" "$DST/.theos"
# Windows 侧编辑过的文件统一去 CRLF（Theos/ldid 对 CRLF 敏感）
find "$DST" -type f \( -name "*.m" -o -name "*.h" -o -name "*.plist" -o -name "*.sh" -o -name "Makefile" -o -name "control" \) -exec sed -i 's/\r$//' {} \; 2>/dev/null

# arm64e PAC 补丁器：工程里没有就从 LSTimeSeconds 构建目录取
if [ ! -f "$DST/tools/patch_arm64e.py" ]; then
    mkdir -p "$DST/tools"
    cp "$HOME/lsts_rootless_5_build/tools/patch_arm64e.py" "$DST/tools/patch_arm64e.py" \
        || die "无法获取 patch_arm64e.py"
fi

cd "$DST" || die "无法进入 $DST"
echo "=== 清理旧产物 ==="
make clean >/dev/null 2>&1 || true
rm -rf packages .theos

echo "=== 编译（clang 19 + ld64 956，arm64 + arm64e，rootless /var/jb）==="
if ! make package FINALPACKAGE=1 \
    THEOS_PACKAGE_INSTALL_PREFIX=/var/jb \
    TARGET_CC="$TC19/clang" TARGET_CXX="$TC19/clang++" TARGET_LD="$TC19/clang++" \
    TARGET_CODESIGN="$TC19/ldid" 2>&1 | tail -60; then
    die "编译失败"
fi

DEB=$(ls -1t packages/*.deb 2>/dev/null | head -1)
[ -n "$DEB" ] || die "没有生成 deb"
echo "生成 deb: $DEB"

echo
echo "=== 解包，做 arm64e PAC 补丁（__cfstring + __objc_data）==="
rm -rf "$DST/repack"; mkdir -p "$DST/repack"
dpkg-deb -R "$DEB" "$DST/repack" || die "dpkg-deb -R 失败"

patch_arm64e() {
    python3 "$DST/tools/patch_arm64e.py" "$1" || die "arm64e PAC 补丁失败: $1"
}

DLDIR="$DST/repack/var/jb/Library/MobileSubstrate/DynamicLibraries"
BNDLDIR="$DST/repack/var/jb/Library/PreferenceBundles/NIPrefs.bundle"
DYLIB="$DLDIR/NotifierIcons.dylib"
PREFS="$BNDLDIR/NIPrefs"
[ -f "$DYLIB" ] || die "包里没有 NotifierIcons.dylib（检查 /var/jb 前缀）"
[ -f "$PREFS" ] || die "包里没有设置面板可执行文件 NIPrefs"

patch_arm64e "$DYLIB" || die "动态库 PAC 补丁失败"
patch_arm64e "$PREFS" || die "设置面板 PAC 补丁失败"

echo "=== 重签（ldid）与权限 ==="
"$TC19/ldid" -S "$DYLIB" || die "ldid 签名失败: dylib"
"$TC19/ldid" -S "$PREFS" || die "ldid 签名失败: 设置面板"
chmod 755 "$DYLIB" "$PREFS"
# Windows 侧拷贝过来的文件常带 777，统一成 iOS 上习惯的 755/644
find "$DST/repack/var/jb" -type d -exec chmod 755 {} +
find "$DST/repack/var/jb" -type f ! -path "$PREFS" ! -path "$DYLIB" -exec chmod 644 {} +

echo "=== 打包 ==="
FINAL_DEB="$SRC/${PKGID}_${VERSION}_iphoneos-arm64.deb"
rm -f "$FINAL_DEB"
dpkg-deb -b -Zxz "$DST/repack" "$FINAL_DEB" || die "dpkg-deb -b 失败"

echo
echo "=== 产物 ==="
ls -lh "$FINAL_DEB"
dpkg-deb -c "$FINAL_DEB"
