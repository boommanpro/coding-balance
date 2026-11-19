#!/usr/bin/env bash
# 构建并打包 CodingBalance.app（菜单栏应用）
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="CodingBalance"

# 版本号：取最近 git tag（v1.4.1 -> 1.4.1），无 tag 时回退 1.0；构建号用提交数
APP_VERSION="$(git describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || true)"
[ -n "$APP_VERSION" ] || APP_VERSION="1.0"
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
echo "==> 版本 $APP_VERSION ($BUILD_NUMBER)"

echo "==> swift build -c release"
swift build -c release

BIN="$(swift build -c release --show-bin-path)/$APP_NAME"
APP="$APP_NAME.app"

echo "==> 组装 $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
cp "AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>CodingBalance</string>
    <key>CFBundleIdentifier</key>
    <string>com.codingbalance.menu</string>
    <key>CFBundleName</key>
    <string>CodingBalance</string>
    <key>CFBundleDisplayName</key>
    <string>Coding Balance</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIconName</key>
    <string>AppIcon</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>__APP_VERSION__</string>
    <key>CFBundleVersion</key>
    <string>__BUILD_NUMBER__</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

# 注入版本号（模板占位符替换）
sed -i '' -e "s/__APP_VERSION__/$APP_VERSION/" -e "s/__BUILD_NUMBER__/$BUILD_NUMBER/" "$APP/Contents/Info.plist"

printf 'APPL????' > "$APP/Contents/PkgInfo"

echo "==> codesign (ad-hoc)"
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "已生成：$(pwd)/$APP"
echo "启动：open $(pwd)/$APP"
