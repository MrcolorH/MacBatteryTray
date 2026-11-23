#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

# 1. 编译
./scripts/build.sh

# 2. 压缩打包
VERSION="v1.0.0"
OUTPUT_ZIP="$PROJECT_DIR/build/MacBatteryTray-${VERSION}.zip"
echo "📦 正在打包应用为 $OUTPUT_ZIP ..."
cd "$PROJECT_DIR/build"
rm -f "$OUTPUT_ZIP"
ditto -c -k --keepParent MacBatteryTray.app "$OUTPUT_ZIP"

echo "✅ 打包完成: $OUTPUT_ZIP"
ls -lh "$OUTPUT_ZIP"
