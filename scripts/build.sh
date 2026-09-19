#!/bin/bash
# 发条屋 构建脚本：编译 + 组装 .app + 安装到 ~/Applications
set -e
cd "$(dirname "$0")/.."

APP_NAME="发条屋"
APP="$(pwd)/build/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"
SRC="$(pwd)/src/main.swift"
RES="$(pwd)/resources"

echo "==> 编译 $APP_NAME"
# 只清产物本身（约十来个文件），不要整棵删 build/ ——
# 整棵删会一次抹掉近两百个中间文件，既没必要，也会被批量删除保护拦住。
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

# 1. 编译
swiftc -O -o "$APP/Contents/MacOS/$APP_NAME" "$SRC"

# 2. 资源
cp "$RES/skin.css" "$APP/Contents/Resources/"
cp "$RES/skin-emerald-light.css" "$APP/Contents/Resources/"
cp "$RES/skin-scarlet.css" "$APP/Contents/Resources/"
cp "$RES/alive.js" "$APP/Contents/Resources/"
# 语音层：波形与交互 UI（原生 SFSpeechRecognizer / AVSpeechSynthesizer 由 main.swift 桥接）
for f in voice.js; do
  [ -f "$RES/$f" ] && cp "$RES/$f" "$APP/Contents/Resources/"
done
# 临时诊断探针（flag 驱动，见 main.swift；不存在就不拷）
[ -f "$RES/probe.js" ] && cp "$RES/probe.js" "$APP/Contents/Resources/"
if [ -f "$RES/AppIcon.icns" ]; then
  cp "$RES/AppIcon.icns" "$APP/Contents/Resources/"
fi
if [ -f "$RES/user-avatar.png" ]; then
  cp "$RES/user-avatar.png" "$APP/Contents/Resources/"
fi

# 3. Info.plist
cat > "$APP/Contents/Info.plist" << 'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleDevelopmentRegion</key>
	<string>zh_CN</string>
	<key>CFBundleExecutable</key>
	<string>发条屋</string>
	<key>CFBundleIdentifier</key>
	<string>com.local.fatiaowu</string>
	<key>CFBundleInfoDictionaryVersion</key>
	<string>6.0</string>
	<key>CFBundleName</key>
	<string>发条屋</string>
	<key>CFBundleDisplayName</key>
	<string>发条屋</string>
	<key>CFBundleIconFile</key>
	<string>AppIcon</string>
	<key>CFBundlePackageType</key>
	<string>APPL</string>
	<key>CFBundleShortVersionString</key>
	<string>2.3.0</string>
	<key>CFBundleVersion</key>
	<string>6</string>
	<key>LSMinimumSystemVersion</key>
	<string>14.0</string>
	<key>NSMicrophoneUsageDescription</key>
	<string>发条屋需要使用麦克风，用于语音输入（本地离线识别，音频不会离开这台 Mac）。</string>
	<key>NSSpeechRecognitionUsageDescription</key>
	<string>发条屋需要语音识别权限，把你说的话转成文字送进对话（使用设备端离线识别）。</string>
	<key>NSAppTransportSecurity</key>
	<dict>
		<key>NSAllowsLocalNetworking</key>
		<true/>
		<key>NSAllowsArbitraryLoads</key>
		<true/>
	</dict>
	<key>LSApplicationCategoryType</key>
	<string>public.app-category.productivity</string>
</dict>
</plist>
PLIST

# 4. 签名（adhoc 即可，无开发者证书）
codesign --force --deep -s - "$APP" >/dev/null 2>&1

# 5. 安装
rm -rf "$DEST"
cp -R "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1

echo "==> 完成: $DEST"
echo "    运行: open \"$DEST\""
