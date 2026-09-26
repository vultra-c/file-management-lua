#!/bin/sh
# 公共函数：读取配置、定位表盘编译器
# 由 build-face.sh / build-all.sh 共同引用。

set -eu

ROOT=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
cd "$ROOT"

# 表盘编译器是 .NET Framework 4.x 可执行文件，来源与 LuaDevTemplate 一致。
# 用固定 commit 拉取，保证 CI 可复现；本地可自行放置覆盖。
COMPILER_COMMIT="0eb8346ce0c9c11f2316c6b154ed91fd4a0d419d"
COMPILER_URL="https://raw.githubusercontent.com/FangAiden/LuaDevTemplate/${COMPILER_COMMIT}/watchface/tools/Compiler.exe"
COMPILER_PATH="watchface/tools/Compiler.exe"

config_get() {
  # config_get <key>  —— 从 watchface.config.json 顶层取字符串值
  node -e '
    const fs = require("fs")
    const cfg = JSON.parse(fs.readFileSync("watchface.config.json", "utf8"))
    const v = process.argv[1].split(".").reduce((o, k) => (o == null ? o : o[k]), cfg)
    if (v == null) process.exit(1)
    process.stdout.write(String(v))
  ' "$1"
}

require_mono() {
  if command -v mono >/dev/null 2>&1; then
    return 0
  fi
  echo "错误：未找到 mono，表盘编译器是 .NET 程序。" >&2
  echo "  Ubuntu/Debian: sudo apt-get install -y mono-devel" >&2
  echo "  macOS:         brew install mono" >&2
  return 1
}

ensure_compiler() {
  if [ -f "$COMPILER_PATH" ]; then
    return 0
  fi
  echo "未找到表盘编译器，正在下载…"
  mkdir -p "$(dirname "$COMPILER_PATH")"
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$COMPILER_URL" -o "$COMPILER_PATH"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$COMPILER_PATH" "$COMPILER_URL"
  else
    echo "错误：需要 curl 或 wget 才能下载表盘编译器。" >&2
    return 1
  fi
  chmod +x "$COMPILER_PATH"
  echo "已下载到 $COMPILER_PATH"
}
