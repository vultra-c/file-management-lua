#!/bin/sh
# 构建 Lua 表盘二进制（.face），并输出到 bin/ 与 watchface/data/resource.bin
#
#   sh ./scripts/build-face.sh
#
# 环境变量：
#   WATCHFACE_ID   覆盖 watchface.config.json 里的表盘 ID
#   FACE_NAME      覆盖产物文件名（默认取 projectName）
#
# 表盘编译器是 .NET Framework 程序，内部用 Windows 风格的 '\' 拼接路径，
# 因此只有 Windows 上能跑通；Linux/macOS 需要 mono 且路径分隔符不兼容，
# 推荐直接用 GitHub Actions 的 windows-latest（见 .github/workflows/build.yml）。

set -eu

. "$(dirname "$0")/lib/common.sh"

PROJECT_NAME=$(config_get projectName)
WATCHFACE_ID=${WATCHFACE_ID:-$(config_get watchfaceId)}
FACE_NAME=${FACE_NAME:-$PROJECT_NAME}

# Windows（含 Git Bash / MSYS）直接跑 exe，其他平台用 mono
RUNNER=""
case "$(uname -s 2>/dev/null || echo Windows)" in
  MINGW* | MSYS* | CYGWIN* | Windows_NT) ;;
  *)
    require_mono
    RUNNER="mono"
    ;;
esac

ensure_compiler

FPRJ="watchface/fprj/${PROJECT_NAME}.fprj"
OUT_DIR="bin"
BIN_DIR="watchface/data"

[ -f "$FPRJ" ] || { echo "错误：缺少表盘工程 $FPRJ（先跑 node scripts/gen-fprj.mjs）" >&2; exit 1; }

mkdir -p "$OUT_DIR" "watchface/fprj/output" "$BIN_DIR"
rm -f "$OUT_DIR/$FACE_NAME" "watchface/fprj/output/$FACE_NAME"

echo "=============================================="
echo "编译表盘: $FPRJ"
echo "产物    : $OUT_DIR/$FACE_NAME"
echo "表盘 ID : $WATCHFACE_ID"
echo "=============================================="

# Compiler.exe -b {fprj 全路径} {输出目录} {产物文件名} {表盘ID}
$RUNNER "$COMPILER_PATH" -b "$(pwd)/$FPRJ" "$OUT_DIR" "$FACE_NAME" "$WATCHFACE_ID"

# 不同版本编译器把产物落在输出目录或工程目录的 output/ 下，两处都找
if [ ! -f "$OUT_DIR/$FACE_NAME" ] && [ -f "watchface/fprj/output/$FACE_NAME" ]; then
  cp -f "watchface/fprj/output/$FACE_NAME" "$OUT_DIR/$FACE_NAME"
fi

[ -f "$OUT_DIR/$FACE_NAME" ] || {
  echo "错误：编译器未产出 $OUT_DIR/$FACE_NAME" >&2
  exit 1
}

# 头部 ID 兜底写入（编译器已写入时是幂等的）
node scripts/patch-face-id.mjs "$OUT_DIR/$FACE_NAME" "$WATCHFACE_ID" ||
  echo "提示：表盘 ID 写入失败，不影响已编译产物" >&2

cp -f "$OUT_DIR/$FACE_NAME" "$BIN_DIR/resource.bin"
echo "已生成: $BIN_DIR/resource.bin ($(wc -c < "$BIN_DIR/resource.bin") 字节)"
