#!/bin/bash
set -e

CERT_NAME="MacBatteryTray Local Signing"

# 检查是否已存在有效的代码签名证书
if security find-identity -v -p codesigning | grep -q "$CERT_NAME"; then
    echo "✅ 固定的本地代码签名证书已存在: $CERT_NAME"
    exit 0
fi

echo "🔑 正在创建固定的本地代码签名证书 ($CERT_NAME)..."
TMP_DIR=$(mktemp -d)
trap "rm -rf '$TMP_DIR'" EXIT

cat << 'EOF' > "$TMP_DIR/cert.cnf"
[ req ]
distinguished_name = req_dn
prompt = no
[ req_dn ]
CN = MacBatteryTray Local Signing
[ v3_req ]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

openssl req -x509 -newkey rsa:2048 -days 3650 -nodes \
  -keyout "$TMP_DIR/cert.key" -out "$TMP_DIR/cert.crt" \
  -config "$TMP_DIR/cert.cnf" -extensions v3_req 2>/dev/null

openssl pkcs12 -legacy -export -out "$TMP_DIR/cert.p12" \
  -inkey "$TMP_DIR/cert.key" -in "$TMP_DIR/cert.crt" \
  -passout pass:macbatterytray -name "$CERT_NAME" 2>/dev/null

# 导入到当前用户的登录钥匙串
security import "$TMP_DIR/cert.p12" \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "macbatterytray" \
  -T /usr/bin/codesign >/dev/null 2>&1 || true

# 标记为当前用户受信任的代码签名根证书（无需管理员密码）
security add-trusted-cert -p codeSign -r trustRoot \
  -k "$HOME/Library/Keychains/login.keychain-db" \
  "$TMP_DIR/cert.crt" >/dev/null 2>&1 || true

# 允许 codesign 无弹窗静默访问私钥
security set-key-partition-list -S apple-tool:,apple:,codesign: -s \
  -k "" "$HOME/Library/Keychains/login.keychain-db" >/dev/null 2>&1 || true

echo "✅ 固定的本地代码签名证书已成功生成并信任！权限将永久绑定此证书。"
