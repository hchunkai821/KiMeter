#!/bin/bash
# 編譯 KiMeter.app（只需要 Xcode Command Line Tools：xcode-select --install）
# UNIVERSAL=1 bash build.sh  → 同時支援 Apple 晶片與 Intel 的通用版
set -euo pipefail
cd "$(dirname "$0")"

APP="build/KiMeter.app"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
rm -rf build
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

compile() {
  xcrun swiftc -O -parse-as-library -sdk "$SDK" \
    -target "$1-apple-macos13.0" Sources/*.swift -o "$2"
}

echo "⚡ 編譯中…"
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  compile arm64  build/KiMeter-arm64
  compile x86_64 build/KiMeter-x86_64
  lipo -create build/KiMeter-arm64 build/KiMeter-x86_64 -output "$APP/Contents/MacOS/KiMeter"
  rm build/KiMeter-arm64 build/KiMeter-x86_64
else
  compile "$(uname -m)" "$APP/Contents/MacOS/KiMeter"
fi

cp Info.plist "$APP/Contents/Info.plist"
if [[ -f Resources/AppIcon.icns ]]; then cp Resources/AppIcon.icns "$APP/Contents/Resources/"; fi
# 強化執行環境（Hardened Runtime）：阻擋外部程式庫注入與執行期竄改
codesign --force --deep --options runtime --timestamp=none -s - "$APP"
codesign --verify --deep --strict "$APP"

echo "✅ 完成：$PWD/$APP"
