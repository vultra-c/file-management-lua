#!/bin/sh
# 生成 aiot toolkit 认可的自签名签名材料。
#
# toolkit 的签名实现是 crypto.createSign('RSA-SHA256') + 自签名 X.509，
# 因此私钥必须是 PKCS#1 格式（-----BEGIN RSA PRIVATE KEY-----），
# 不能用 PKCS#8（-----BEGIN PRIVATE KEY-----）。
#
#   sh ./scripts/gen-signing.sh
#
# 产物写入 sign/release/，已在 .gitignore 中，不会进仓库。
# CI 里请用 Secrets 还原真实的证书，不要在日志里回显。

set -eu

. "$(dirname "$0")/lib/common.sh"

command -v openssl >/dev/null 2>&1 || { echo "错误：需要 openssl" >&2; exit 1; }

CN=${FM_CERT_CN:-com.vultra.fmanager}
DAYS=${FM_CERT_DAYS:-3650}
OUT="sign/release"

mkdir -p "$OUT"
cd "$OUT"

# PKCS#1 私钥：openssl 3.x 需要显式 -traditional
if openssl genrsa -traditional -out private.pem 4096 2>/dev/null; then
  :
else
  openssl genrsa -out private.pem 4096
  openssl rsa -in private.pem -traditional -out private.pem.tmp 2>/dev/null && mv private.pem.tmp private.pem
fi

openssl req -new -x509 -sha256 -days "$DAYS" \
  -key private.pem -out certificate.pem \
  -subj "/CN=$CN/O=Vultra-C"

cd "$ROOT"

echo "已生成自签名材料:"
echo "  $OUT/private.pem       (PKCS#1 RSA 私钥，请勿提交)"
echo "  $OUT/certificate.pem   (X.509 证书)"
