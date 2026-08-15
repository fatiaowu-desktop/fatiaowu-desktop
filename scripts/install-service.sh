#!/bin/bash
# 发条屋 后台服务安装脚本：安装 DSH 服务的 launchd 常驻代理
# 用法: ./scripts/install-service.sh
set -e
cd "$(dirname "$0")/.."

HOME_DIR="$HOME"
SERVICE_DIR="$HOME/.dsh"
BIN_DIR="$SERVICE_DIR/bin"
LOG_DIR="$SERVICE_DIR/logs"
PLIST_DEST="$HOME/Library/LaunchAgents/com.local.dsh-server.plist"

echo "==> 创建目录"
mkdir -p "$BIN_DIR" "$LOG_DIR"

echo "==> 安装服务包装脚本到 $BIN_DIR/dsh-server.sh"
cp service/dsh-server.sh "$BIN_DIR/dsh-server.sh"
chmod +x "$BIN_DIR/dsh-server.sh"

echo "==> 生成 launchd plist（替换 \$HOME）"
sed "s|__HOME__|$HOME_DIR|g" service/com.local.dsh-server.plist > "$PLIST_DEST"

echo "==> 加载服务"
launchctl unload "$PLIST_DEST" >/dev/null 2>&1 || true
launchctl load "$PLIST_DEST"

echo "==> 完成。服务已注册："
launchctl list | grep dsh-server || echo "（服务将由登录后自动启动，或现在立即启动）"
launchctl start com.local.dsh-server 2>/dev/null || true
sleep 2
if curl -s -o /dev/null http://127.0.0.1:3080/; then
  echo "==> DSH 服务已在 http://127.0.0.1:3080 运行 ✓"
else
  echo "==> 服务启动中… 日志见 $LOG_DIR/dsh-server.out.log"
fi
