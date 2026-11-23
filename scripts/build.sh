#!/bin/bash
set -e

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_DIR"

echo "================================================"
echo "🚀 开始构建 MacBatteryTray 原生 macOS 应用"
echo "================================================"

BUILD_DIR="$PROJECT_DIR/build"
APP_BUNDLE="$BUILD_DIR/MacBatteryTray.app"
PLUGINS_DIR="$APP_BUNDLE/Contents/PlugIns"
EXT_BUNDLE="$PLUGINS_DIR/BatteryControlExtension.appex"

# 1. 确保固定本地签名证书存在
chmod +x "$PROJECT_DIR/scripts/setup_cert.sh"
"$PROJECT_DIR/scripts/setup_cert.sh"

SIGN_IDENTITY="MacBatteryTray Local Signing"
if ! security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY"; then
    echo "⚠️ 未找到 $SIGN_IDENTITY，将回退至临时签名"
    SIGN_IDENTITY="-"
fi

# 2. 清理并准备目录
echo "📁 [1/5] 准备产物目录与资源..."
rm -rf "$BUILD_DIR"
mkdir -p "$APP_BUNDLE/Contents/MacOS"
mkdir -p "$APP_BUNDLE/Contents/Resources"
mkdir -p "$EXT_BUNDLE/Contents/MacOS"
mkdir -p "$EXT_BUNDLE/Contents/Resources"

# 复制 AppIcon
if [ -f "$PROJECT_DIR/MacBatteryTray/Resources/AppIcon.icns" ]; then
    cp "$PROJECT_DIR/MacBatteryTray/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
fi

# 复制 Metadata.appintents 供系统 WidgetKit / AppIntents 引擎解析控制描述符
if [ -d "$PROJECT_DIR/BatteryControlExtension/Metadata.appintents" ]; then
    cp -R "$PROJECT_DIR/BatteryControlExtension/Metadata.appintents" "$EXT_BUNDLE/Contents/Resources/"
fi

# 3. 编译 BatteryControlExtension (WidgetKit 桌面组件与控制中心扩展)
echo "⚡ [2/5] 编译 BatteryControlExtension 控制中心扩展..."
clang -c -fno-objc-arc \
  -target arm64-apple-macos15.0 \
  BatteryControlExtension/ExtensionBootstrapHook.m \
  -o "$BUILD_DIR/ExtensionBootstrapHook.o"

xcrun -sdk macosx swiftc -O -wmo \
  -module-name BatteryControlExtension \
  -target arm64-apple-macos15.0 \
  -framework AppKit -framework SwiftUI -framework WidgetKit -framework AppIntents \
  -Xlinker -e -Xlinker _NSExtensionMain \
  Shared/Models/PeripheralBattery.swift \
  Shared/Storage/BatteryStore.swift \
  BatteryControlExtension/RefreshBatteryIntent.swift \
  BatteryControlExtension/BatteryDesktopWidget.swift \
  BatteryControlExtension/BatteryControlWidget.swift \
  BatteryControlExtension/BatteryControlWidgetBundle.swift \
  "$BUILD_DIR/ExtensionBootstrapHook.o" \
  -o "$EXT_BUNDLE/Contents/MacOS/BatteryControlExtension"

# 生成 Extension Info.plist
cat << 'EOF' > "$EXT_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>外设电量</string>
    <key>CFBundleExecutable</key>
    <string>BatteryControlExtension</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.MacBatteryTray.BatteryControlExtension</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>BatteryControlExtension</string>
    <key>CFBundlePackageType</key>
    <string>XPC!</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleSupportedPlatforms</key>
    <array>
        <string>MacOSX</string>
    </array>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key>
        <string>com.apple.widgetkit-extension</string>
    </dict>
</dict>
</plist>
EOF

# 对 Extension 进行签名
echo "🔏 对 BatteryControlExtension 进行代码签名 ($SIGN_IDENTITY)..."
codesign -s "$SIGN_IDENTITY" --force -o runtime --entitlements "$PROJECT_DIR/BatteryControlExtension/BatteryControlExtension.entitlements" "$EXT_BUNDLE"

# 4. 编译 MacBatteryTray 主程序
echo "⚡ [3/5] 编译 MacBatteryTray 主程序..."
xcrun -sdk macosx swiftc -O -wmo \
  -target arm64-apple-macos15.0 \
  -framework AppKit -framework SwiftUI -framework IOKit -framework WidgetKit -framework ServiceManagement -framework UserNotifications \
  Shared/Models/PeripheralBattery.swift \
  Shared/Storage/BatteryStore.swift \
  MacBatteryTray/Drivers/HIDBatteryDriver.swift \
  MacBatteryTray/Drivers/RazerHIDDriver.swift \
  MacBatteryTray/Drivers/RazerHeadsetHIDDriver.swift \
  MacBatteryTray/Drivers/LogitechHIDDriver.swift \
  MacBatteryTray/Drivers/CompXHIDDriver.swift \
  MacBatteryTray/Drivers/RongyuanHIDDriver.swift \
  MacBatteryTray/Drivers/SteelSeriesHIDDriver.swift \
  MacBatteryTray/Drivers/HyperXHeadsetDriver.swift \
  MacBatteryTray/Drivers/XentaHIDDriver.swift \
  MacBatteryTray/Drivers/IrokHIDDriver.swift \
  MacBatteryTray/Drivers/StandardHIDBatteryDriver.swift \
  MacBatteryTray/Drivers/BluetoothHIDBatteryReader.swift \
  MacBatteryTray/Engine/AutoLaunchManager.swift \
  MacBatteryTray/Engine/BatteryNotificationManager.swift \
  MacBatteryTray/Engine/HIDBatteryManager.swift \
  MacBatteryTray/App/AppDelegate.swift \
  MacBatteryTray/App/MacBatteryTrayApp.swift \
  -o "$APP_BUNDLE/Contents/MacOS/MacBatteryTray"

# 生成主程序 Info.plist (增加 CFBundleDisplayName 与本地化搜索适配)
cat << 'EOF' > "$APP_BUNDLE/Contents/Info.plist"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key>
    <string>zh_CN</string>
    <key>CFBundleDisplayName</key>
    <string>外设电量</string>
    <key>CFBundleExecutable</key>
    <string>MacBatteryTray</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon</string>
    <key>CFBundleIdentifier</key>
    <string>com.local.MacBatteryTray</string>
    <key>CFBundleInfoDictionaryVersion</key>
    <string>6.0</string>
    <key>CFBundleName</key>
    <string>外设电量</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>1.0.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSApplicationCategoryType</key>
    <string>public.app-category.utilities</string>
    <key>LSMinimumSystemVersion</key>
    <string>15.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>MDItemKeywords</key>
    <string>外设,电量,Battery,雷蛇,罗技,鼠标,键盘,耳机</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSInputMonitoringUsageDescription</key>
    <string>需要访问HID设备以读取2.4G无线外设的电量</string>
</dict>
</plist>
EOF

# 5. 对整个 App Bundle 进行签名（注：禁止使用 --deep，避免覆盖扩展内部独立的沙盒 entitlements）
echo "🔏 [4/5] 对 MacBatteryTray.app 进行完整签名 ($SIGN_IDENTITY)..."
codesign -s "$SIGN_IDENTITY" --force -o runtime --entitlements "$PROJECT_DIR/MacBatteryTray/MacBatteryTray.entitlements" "$APP_BUNDLE"

# 6. 校验签名与注册 LaunchServices
echo "🔍 [5/5] 验证签名有效性并注册系统服务..."
codesign -vvv "$APP_BUNDLE"
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP_BUNDLE"

echo "================================================"
echo "✅ 构建成功！已绑定固定签名证书，权限永久保存。"
echo "📦 产物路径: $APP_BUNDLE"
echo "================================================"
