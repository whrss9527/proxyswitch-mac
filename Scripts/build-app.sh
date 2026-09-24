#!/bin/bash
# 编译并组装 ProxySwitch.app（通用二进制），带上内核 mihomo 和 GeoIP 数据库，ad-hoc 签名后打成 dist/ProxySwitch-macos.zip。
#   VERSION=1.0.0 Scripts/build-app.sh          发布构建
#   CONFIG=debug ARCHS="" Scripts/build-app.sh   本机架构的调试构建
#   SKIP_CORE=1 Scripts/build-app.sh             不下载内核（只能用外部代理的功能）
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${VERSION:-0.1.0}"
BUILD="${BUILD:-$(date +%Y%m%d%H%M)}"
CONFIG="${CONFIG:-release}"
ARCHS="${ARCHS---arch arm64 --arch x86_64}"
CORE_VERSION="${CORE_VERSION:-v1.19.31}"
CORE_CACHE="${CORE_CACHE:-.core-cache}"

# 下载到缓存目录，已有就跳过。
fetch() {
  local url="$1" dest="$2"
  if [ -s "$dest" ]; then return 0; fi
  echo "下载 $url"
  curl -fsSL --retry 3 --retry-delay 3 -o "$dest.tmp" "$url" && mv "$dest.tmp" "$dest"
}

# shellcheck disable=SC2086
swift build -c "$CONFIG" $ARCHS --product ProxySwitch
# shellcheck disable=SC2086
BIN_DIR="$(swift build -c "$CONFIG" $ARCHS --show-bin-path)"

APP="dist/ProxySwitch.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$VERSION/g" -e "s/__BUILD__/$BUILD/g" Resources/Info.plist > "$APP/Contents/Info.plist"
cp "$BIN_DIR/ProxySwitch" "$APP/Contents/MacOS/ProxySwitch"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -z "${SKIP_CORE:-}" ]; then
  # 内核：mihomo（Clash Meta），两个架构的发布包合成一个通用二进制。
  mkdir -p "$CORE_CACHE"
  for arch in arm64 amd64-compatible; do
    gz="$CORE_CACHE/mihomo-darwin-$arch-$CORE_VERSION.gz"
    fetch "https://github.com/MetaCubeX/mihomo/releases/download/$CORE_VERSION/mihomo-darwin-$arch-$CORE_VERSION.gz" "$gz"
    gunzip -c "$gz" > "$CORE_CACHE/mihomo-$arch"
    chmod +x "$CORE_CACHE/mihomo-$arch"
  done
  lipo -create -output "$APP/Contents/MacOS/mihomo" "$CORE_CACHE/mihomo-arm64" "$CORE_CACHE/mihomo-amd64-compatible"
  chmod +x "$APP/Contents/MacOS/mihomo"
  # GeoIP 数据库（GEOIP,CN 规则要用）。
  fetch "https://github.com/MetaCubeX/meta-rules-dat/releases/download/latest/country.mmdb" "$CORE_CACHE/country.mmdb" \
    || fetch "https://cdn.jsdelivr.net/gh/MetaCubeX/meta-rules-dat@release/country.mmdb" "$CORE_CACHE/country.mmdb"
  cp "$CORE_CACHE/country.mmdb" "$APP/Contents/Resources/country.mmdb"
  fetch "https://raw.githubusercontent.com/MetaCubeX/mihomo/$CORE_VERSION/LICENSE" "$CORE_CACHE/mihomo-LICENSE.txt"
  cp "$CORE_CACHE/mihomo-LICENSE.txt" "$APP/Contents/Resources/mihomo-LICENSE.txt"
  codesign --force --sign "${CODESIGN_IDENTITY:--}" "$APP/Contents/MacOS/mihomo"
  echo "内核 mihomo ${CORE_VERSION}：$(lipo -archs "${APP}/Contents/MacOS/mihomo")"
fi

# 没有开发者证书时用 ad-hoc 签名，Apple 芯片上必须有签名才能运行。
codesign --force --deep --sign "${CODESIGN_IDENTITY:--}" "$APP"

(cd dist && rm -f ProxySwitch-macos.zip && ditto -c -k --keepParent ProxySwitch.app ProxySwitch-macos.zip)
echo "已生成 ${APP} 和 dist/ProxySwitch-macos.zip（版本 ${VERSION}）"
