#!/bin/bash
PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if [ -d "/Applications/MacBatteryTray.app" ]; then
    APP_PATH="/Applications/MacBatteryTray.app"
elif [ -d "$HOME/Applications/MacBatteryTray.app" ]; then
    APP_PATH="$HOME/Applications/MacBatteryTray.app"
else
    APP_PATH="$PROJECT_DIR/build/MacBatteryTray.app"
fi

if [ ! -d "$APP_PATH" ]; then
    echo "⚠️ 未检测到构建产物，正在自动执行构建与安装..."
    "$PROJECT_DIR/scripts/build.sh"
    "$PROJECT_DIR/scripts/install.sh"
    APP_PATH="/Applications/MacBatteryTray.app"
fi

# 杀死旧实例
pkill -f "MacBatteryTray.app/Contents/MacOS/MacBatteryTray" 2>/dev/null || true

echo "🚀 正在启动 $APP_PATH ..."
open "$APP_PATH"

echo "================================================"
echo "💡 提示："
echo "1. 应用已启动，请查看顶部菜单栏图标与电量数据。"
echo "2. 签名已永久固化，在【系统设置 -> 隐私与安全性 -> 输入监控】中只需授权一次，后续永不失效。"
echo "3. 如何将磁贴放入控制中心："
echo "   - 点击 macOS 屏幕右上角【控制中心】图标（调节音量/亮度的双开关图标）"
echo "   - 点击面板最下方的【编辑控制项】（Edit Controls）"
echo "   - 在控制项列表中找到【外设电量】（MacBatteryTray），点击 '+' 或直接拖动添加到控制中心面板！"
echo "================================================"
