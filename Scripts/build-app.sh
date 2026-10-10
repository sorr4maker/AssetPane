#!/bin/bash
# 打包成可以双击运行的 AssetPane.app（菜单栏 + 桌面面板）
# 用法：Scripts/build-app.sh            → 生成 build/AssetPane.app
#       Scripts/build-app.sh --install  → 同时安装到 ~/Applications
# 网页部分来自 ~/Developer/real-time-fund（先在那边 npm run build，生成 out 目录）
set -euo pipefail
cd "$(dirname "$0")/.."

WEB_SRC="${WEB_SRC:-$HOME/Developer/real-time-fund/out}"
[[ -f "$WEB_SRC/index.html" ]] || { echo "找不到 $WEB_SRC/index.html，请先在 real-time-fund 里 npm run build"; exit 1; }

swift build -c release --product AssetPane
BIN="$(swift build -c release --product AssetPane --show-bin-path)/AssetPane"

APP="build/AssetPane.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/AssetPane"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[[ -f Resources/AppIcon.icns ]] && cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
cp -R "$WEB_SRC" "$APP/Contents/Resources/web"
codesign --force --deep --sign - "$APP"   # ad-hoc 签名，本机运行足够
echo "已生成 $APP"

if [[ "${1:-}" == "--install" ]]; then
    mkdir -p ~/Applications
    rm -rf ~/Applications/AssetPane.app
    cp -R "$APP" ~/Applications/
    echo "已安装到 ~/Applications/AssetPane.app"
fi
