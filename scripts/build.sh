#!/bin/bash
# 发条屋 构建脚本：编译 + 组装 .app + 安装到 ~/Applications
set -e
cd "$(dirname "$0")/.."

APP_NAME="发条屋"
APP="$(pwd)/build/$APP_NAME.app"
DEST="$HOME/Applications/$APP_NAME.app"
SRC="$(pwd)/src/main.swift"
RES="$(pwd)/resources"

# 守卫：装机那一步会 rm -rf "$DEST"。如果 app 正在运行，这会拆掉它脚下的包，
# 而且残留的 *.cstemp 会让随后的 codesign --deep 级联失败。先确认没在跑。
RUNNING="$(pgrep -f "$APP_NAME.app/Contents/MacOS" 2>/dev/null || true)"
if [ -n "$RUNNING" ]; then
  echo "❌ $APP_NAME 正在运行（pid: $(printf '%s' "$RUNNING" | tr '\n' ' ')）"
  echo "   本脚本会 rm -rf 装机目标，可能破坏正在运行的实例；签名也会失败。"
  echo "   请先退出 ${APP_NAME}（或 osascript -e 'quit app \"${APP_NAME}\"'）再重试。"
  exit 1
fi

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
cp "$RES/skin-cyber.css" "$APP/Contents/Resources/"
# （alive.js 已于 2.15.2 移除：窗口内生灵层退役，交互全在 deskpet.html）
# 「放生」层：桌面小鲸鱼页面（独立全屏透明浮层，由 DeskPetController 加载）
cp "$RES/deskpet.html" "$APP/Contents/Resources/"
# 灵动岛（躲猫猫）：顶部黑色胶囊 + 两只眼（IslandController 加载）
cp "$RES/island.html" "$APP/Contents/Resources/"
# 玻璃穹顶（回笼，2.18.0）：主窗口子视图加载的穹顶页面（CageOverlayController）
cp "$RES/cage.html" "$APP/Contents/Resources/"
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
	<string>2.28.6</string>
	<key>CFBundleVersion</key>
	<string>94</string>
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
# 失败要显式报出来：静默失败会留下一份没签成的包，或者残留 *.cstemp 让下次更糟。
if ! CODESIGN_OUT="$(codesign --force --deep -s - "$APP" 2>&1)"; then
  echo "❌ adhoc 签名失败："
  printf '%s\n' "$CODESIGN_OUT" | sed 's/^/   /'
  echo "   常见原因：有进程正持有该包内的可执行文件（先退出 ${APP_NAME}），"
  echo "   或包内残留 *.cstemp（rm -f \"$APP/Contents/MacOS/\"*.cstemp 后重试）。"
  exit 1
fi

# 5. 安装
rm -rf "$DEST"
cp -R "$APP" "$DEST"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" >/dev/null 2>&1

echo "==> 完成: $DEST"
echo "    运行: open \"$DEST\""
