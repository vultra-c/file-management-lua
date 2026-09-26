#!/bin/sh
# 一次构建全部产物：Vela 轻应用 .rpk + Lua 表盘 .face
#
#   sh ./scripts/build-all.sh
#
# 签名说明：
#   aiot release（PRODUCTION 模式）按以下优先级找证书，都找不到就用 toolkit 内置调试证书：
#     1. sign/release/private.pem  + sign/release/certificate.pem
#     2. sign/private.pem          + sign/certificate.pem
#   仓库不提交任何签名材料，CI 用 Secrets 还原到 sign/ 下。
#   本地没有证书时会自动生成一套自签名（scripts/gen-signing.sh）。

set -eu

. "$(dirname "$0")/lib/common.sh"

echo ">>> [1/4] 生成表盘预览图与工程文件"
node scripts/gen-fprj.mjs
node scripts/gen-preview.mjs

echo ">>> [2/4] 生成列表图标"
node scripts/gen-icons.mjs

echo ">>> [3/4] 构建 Vela 轻应用 (.rpk)"
if [ ! -f sign/release/private.pem ] && [ ! -f sign/private.pem ] && [ "${FM_SKIP_SIGNING:-0}" != "1" ]; then
  echo "未发现签名材料，生成自签名证书…"
  sh ./scripts/gen-signing.sh
fi
npx --no-install aiot release --enable-jsc

echo ">>> [4/4] 构建 Lua 表盘 (.face)"
if command -v mono >/dev/null 2>&1; then
  sh ./scripts/build-face.sh
else
  echo "提示：未安装 mono，跳过表盘构建（CI 中会安装 mono）" >&2
  echo "      sh ./scripts/build-face.sh 可在装好 mono 的环境单独构建。" >&2
fi

echo
echo "=============================================="
echo "构建完成，产物："
find dist bin watchface/data -type f 2>/dev/null | while read -r f; do
  echo "  $f ($(wc -c < "$f") 字节)"
done
echo "=============================================="
