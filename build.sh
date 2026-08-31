#!/bin/bash
# 构建 DMG Library.app
#
# 用法：
#   ./build.sh            # release 构建并打包
#   ./build.sh --debug    # debug 构建
#   ./build.sh --run      # 构建完成后立即运行
set -euo pipefail

cd "$(dirname "$0")"

APP_NAME="DMG Library"
EXEC_NAME="DMGLibrary"
DIST_DIR="dist"
CONFIG="release"
SHOULD_RUN=false

for argument in "$@"; do
    case "$argument" in
        --debug) CONFIG="debug" ;;
        --run) SHOULD_RUN=true ;;
        *) echo "未知参数：$argument"; exit 1 ;;
    esac
done

APP_PATH="$DIST_DIR/$APP_NAME.app"

echo "==> 构建 ($CONFIG)"
# SPM 清单编译在当前环境下需要关闭沙箱
swift build -c "$CONFIG" --disable-sandbox

echo "==> 生成 App 图标"
ICON_DIR=".build/icon"
swift Scripts/make_icon.swift "$ICON_DIR" > /dev/null
rm -rf "$ICON_DIR/AppIcon.icns"
iconutil -c icns "$ICON_DIR/AppIcon.iconset" -o "$ICON_DIR/AppIcon.icns"

echo "==> 组装 $APP_PATH"
rm -rf "$APP_PATH"
mkdir -p "$APP_PATH/Contents/MacOS"
mkdir -p "$APP_PATH/Contents/Resources"

cp ".build/$CONFIG/$EXEC_NAME" "$APP_PATH/Contents/MacOS/$EXEC_NAME"
cp "Resources/Info.plist" "$APP_PATH/Contents/Info.plist"
cp "$ICON_DIR/AppIcon.icns" "$APP_PATH/Contents/Resources/AppIcon.icns"

# ad-hoc 签名：本地运行与文件访问更顺畅
codesign --force --deep --sign - "$APP_PATH" 2>/dev/null || true

echo "==> 完成：$APP_PATH"

if [ "$SHOULD_RUN" = true ]; then
    echo "==> 启动"
    open "$APP_PATH"
fi
