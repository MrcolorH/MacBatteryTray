#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_PATH="$PROJECT_DIR/build/MacBatteryTray.app"

if [ ! -d "$APP_PATH" ]; then
    echo "⚠️ 正在执行初次构建..."
    "$PROJECT_DIR/scripts/build.sh"
fi

TARGET_DIR="/Applications"
TARGET_APP="$TARGET_DIR/MacBatteryTray.app"

echo "📦 正在安装至 $TARGET_APP ..."
pkill -f "MacBatteryTray.app/Contents/MacOS/MacBatteryTray" 2>/dev/null || true
rm -rf "$TARGET_APP"
cp -R "$APP_PATH" "$TARGET_DIR/"

# 刷新系统 LaunchServices 注册表与 PlugInKit
echo "🔄 注册 LaunchServices & PlugInKit..."
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$TARGET_APP"
pluginkit -a "$TARGET_APP/Contents/PlugIns/BatteryControlExtension.appex"

# 重置 chronod 与 ControlCenter 缓存，强制重新加载控制中心磁贴
echo "🔄 刷新控制中心与 WidgetKit 服务缓存..."
killall -9 chronod 2>/dev/null || true
killall -9 ControlCenter 2>/dev/null || true

# 重新启动主程序
echo "🚀 启动外设电量主程序..."
open -a "$TARGET_APP"

echo "================================================"
echo "✅ 安装完成！"
echo "应用位置: $TARGET_APP"
echo "已绑定固定证书签名，权限无需重复配置。"
echo "================================================"
