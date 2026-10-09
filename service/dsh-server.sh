#!/bin/bash
# 发条屋后台服务包装脚本 —— 由 launchd 常驻管理，不依赖任何终端
# 自动定位 DeepSeek Harness 的入口脚本（支持 DSH_BIN / DSH_VERSION 环境变量覆盖）
#
# 定位坑（2026-10-08 实测修正，此前的写法因此从未生效过）：
#   ① dsh 的入口是 <pkg>/lib/bin.js（该包 package.json 里 "bin": {"dsh": "lib/bin.js"}），
#      不是 <pkg>/bin.js —— 旧写法 `-path '*@deepseek-ai/dsh/bin.js'` 命中数恒为 0，
#      等于这个兜底分支是死的。
#   ② npx 缓存目录名是随机哈希（~/.npm/_npx/<hash>/node_modules/...），
#      会随重新解析而改变，所以不能写死路径。
#   ③ 对 ~/.npm/_npx 做深层 find 很慢（实测会被系统掐断），所以只用定深 glob 定位。

NODE="${NODE:-$(command -v node)}"
if [ -z "$NODE" ]; then
  echo "错误: 找不到 node，请先安装 Node.js 18+" >> "$HOME/.dsh/logs/dsh-server.err.log"
  exit 1
fi

# 冻结的 DSH 版本（与 README「已冻结的兼容基线」一致）。
# npx 缓存里出现多个版本时优先用它；置空则任意版本都接受。
DSH_VERSION="${DSH_VERSION:-0.1.5-rc.2}"

# 所有候选 dsh 的 package.json（npx 缓存 + 各全局安装位置；定深 glob，毫秒级）
dsh_pkgs() {
  local base
  for base in \
    "$HOME"/.npm/_npx/*/node_modules \
    "$HOME"/.npm-global/lib/node_modules \
    /usr/local/lib/node_modules \
    /opt/homebrew/lib/node_modules; do
    [ -f "$base/@deepseek-ai/dsh/package.json" ] && printf '%s\n' "$base/@deepseek-ai/dsh/package.json"
  done
}

# $1 = 期望版本（空 = 不限制版本）；找到入口脚本则打印它的路径并以 0 返回
find_dsh() {
  local want="$1" pj dir cand
  while IFS= read -r pj; do
    if [ -n "$want" ]; then
      grep -q "\"version\"[[:space:]]*:[[:space:]]*\"$want\"" "$pj" 2>/dev/null || continue
    fi
    dir="$(dirname "$pj")"
    for cand in "$dir/lib/bin.js" "$dir/bin.js"; do
      if [ -f "$cand" ]; then printf '%s\n' "$cand"; return 0; fi
    done
  done < <(dsh_pkgs)
  return 1
}

# 定位入口：① 环境变量 DSH_BIN ② PATH 里的 dsh（仅当它是 JS 入口）
#           ③ npx/全局缓存（先按冻结版本，再兜底任意版本）
if [ -z "$DSH_BIN" ]; then
  cand="$(command -v dsh 2>/dev/null || true)"
  case "$cand" in
    *.js|*.mjs|*.cjs) DSH_BIN="$cand" ;;
    "") ;;
    *) echo "[$(date)] 跳过非 JS 入口的 dsh: ${cand}（改用缓存里的）" >> "$HOME/.dsh/logs/dsh-server.out.log" ;;
  esac
fi
if [ -z "$DSH_BIN" ]; then
  DSH_BIN="$(find_dsh "$DSH_VERSION")"
fi
if [ -z "$DSH_BIN" ]; then
  DSH_BIN="$(find_dsh "")"
fi
if [ -z "$DSH_BIN" ]; then
  echo "错误: 找不到 DSH (deepseek-harness)。请运行 npx -y @deepseek-ai/dsh@$DSH_VERSION web 安装" >> "$HOME/.dsh/logs/dsh-server.err.log"
  exit 1
fi

PORT="${PORT:-3080}"

# 端口已被占用（例如旧实例还在跑）→ 静默退出，launchd 会自动重试；
# 旧实例一退出，这里就能接管端口。
if lsof -i ":$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "[$(date)] 端口 $PORT 已被占用，等待重试" >> "$HOME/.dsh/logs/dsh-server.out.log"
  exit 0
fi

# --no-open：后台常驻不要弹浏览器（dsh web 默认会 open 默认浏览器，见 dsh-web-app/lib/index.js）
exec "$NODE" "$DSH_BIN" web --port "$PORT" --no-open >> "$HOME/.dsh/logs/dsh-server.out.log" 2>> "$HOME/.dsh/logs/dsh-server.err.log"
