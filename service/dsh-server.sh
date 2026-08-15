#!/bin/bash
# 发条屋后台服务包装脚本 —— 由 launchd 常驻管理，不依赖任何终端
# 自动定位 DeepSeek Harness 的 bin.js（支持 DSH_BIN 环境变量覆盖）

NODE="${NODE:-$(command -v node)}"
if [ -z "$NODE" ]; then
  echo "错误: 找不到 node，请先安装 Node.js 18+" >> "$HOME/.dsh/logs/dsh-server.err.log"
  exit 1
fi

# 定位 DSH bin.js：优先环境变量，其次 PATH 里的 dsh，最后在 npx 缓存里找
if [ -z "$DSH_BIN" ]; then
  DSH_BIN="$(command -v dsh 2>/dev/null || true)"
fi
if [ -z "$DSH_BIN" ]; then
  DSH_BIN="$(find "$HOME/.npm/_npx" -maxdepth 4 -path '*@deepseek-ai/dsh/bin.js' 2>/dev/null | head -1)"
fi
if [ -z "$DSH_BIN" ]; then
  echo "错误: 找不到 DSH (deepseek-harness)，请先运行 npx -y @deepseek-ai/dsh web 安装" >> "$HOME/.dsh/logs/dsh-server.err.log"
  exit 1
fi

PORT="${PORT:-3080}"

# 如果端口已被占用（例如旧实例还在跑），静默等待后退出，
# launchd 会在几秒后自动重试；旧实例一退出，这里就能接管端口。
if lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[$(date)] 端口 $PORT 已被占用，等待重试" >> "$HOME/.dsh/logs/dsh-server.out.log"
  exit 0
fi

exec "$NODE" "$DSH_BIN" web --port "$PORT" >> "$HOME/.dsh/logs/dsh-server.out.log" 2>> "$HOME/.dsh/logs/dsh-server.err.log"
