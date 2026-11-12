# Eye Rest Guard · 护眼守卫

一个使用 Swift 编写的 macOS 护眼休息提醒程序。默认每隔 30 分钟显示一次 40 秒的休息遮罩，提示离开屏幕、看向远处。

核心程序完整保存在 `eye_rest_guard.swift` 中，界面由代码构建，只依赖 macOS 系统框架，不需要第三方库、外部图片或网络服务。

## 功能

- 休息遮罩包含呼吸动画、倒计时以及开始和结束提示音。
- 全局快捷键 **⌘ + ;** 可立即触发休息。
- **1.5 秒内连按三次 Esc** 可提前结束休息。
- 控制面板支持暂停 1 小时、今天不再提醒、恢复提醒、立即测试和退出。
- 屏幕关闭后，唤醒时重新计算提醒间隔；已暂停时保留暂停状态。
- 后台运行，不显示 Dock 图标或菜单栏图标。

## 编译与运行

需要 macOS，以及提供 Swift 编译器和 macOS SDK 的 Xcode 或 Xcode Command Line Tools。编译后的程序运行时不需要开发工具。

如果尚未安装命令行开发工具：

```sh
xcode-select --install
```

克隆仓库，在仓库根目录编译并运行：

```sh
git clone https://github.com/zhijun42/eye-rest-guard.git
cd eye-rest-guard
swiftc eye_rest_guard.swift -o eye_rest_guard
./eye_rest_guard
```

启动后会等待完整的提醒间隔，按 **⌘ + ;** 可以立即查看效果。同一时间运行一个实例即可。

编译结果 `eye_rest_guard` 已加入 `.gitignore`，仓库保留源码和配置。

## 调整提醒时间

通过环境变量设置，单位均为秒：

| 变量 | 默认值 | 用途 |
| --- | --- | --- |
| `EYE_INTERVAL` | `1800` | 每次休息结束后，到下一次提醒的间隔 |
| `EYE_DURATION` | `40` | 每次休息时长 |
| `EYE_DEBUG` | 未设置 | 设置后向标准错误输出诊断日志 |

例如，每隔 60 秒提醒休息 10 秒：

```sh
EYE_INTERVAL=60 EYE_DURATION=10 EYE_DEBUG=1 ./eye_rest_guard
```

提醒间隔和休息时长必须为正数，无法解析的值会使用默认值。暂停状态只保存在内存中，进程重新启动后会重置。

## 打开控制面板

程序运行时，在终端执行：

```sh
pkill -USR1 -x eye_rest_guard
```

这会唤出源码内置的控制面板。

也可以将 `extras/control.applescript` 编译成可双击的“护眼控制.app”：

```sh
mkdir -p "$HOME/Applications"
osacompile -o "$HOME/Applications/护眼控制.app" extras/control.applescript
```

控制程序负责发送信号；如果后台程序未运行，会尝试通过下方的 LaunchAgent 启动它。用户 ID 会在运行时读取。

## 登录后自动启动

先完成编译。以下命令需要在仓库根目录执行，会将当前仓库中的可执行文件绝对路径写入配置：

```sh
mkdir -p "$HOME/Library/LaunchAgents"
cp extras/com.zhijun.eye_rest_guard.plist "$HOME/Library/LaunchAgents/com.zhijun.eye_rest_guard.plist"
/usr/bin/plutil -replace ProgramArguments.0 -string "$PWD/eye_rest_guard" "$HOME/Library/LaunchAgents/com.zhijun.eye_rest_guard.plist"
launchctl bootstrap "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.zhijun.eye_rest_guard.plist"
```

配置使用 `RunAtLoad` 和 `KeepAlive`，会在加载时启动程序，并在程序退出后重新启动。启用后，控制面板中的“退出护眼守卫”也会触发自动重启。

如果已经安装同名 LaunchAgent，先执行下面的 `launchctl bootout` 命令，再安装新配置；也应先退出手动运行的实例。移动仓库目录后，需要重新更新可执行文件路径并加载配置。

若要为自动启动的实例设置提醒时间，在安装后的 plist 中增加 `EnvironmentVariables` 字典，例如：

```xml
<key>EnvironmentVariables</key>
<dict>
    <key>EYE_INTERVAL</key>
    <string>1800</string>
    <key>EYE_DURATION</key>
    <string>40</string>
</dict>
```

该字典放在 plist 最外层的 `<dict>` 中。保存后卸载并重新加载 LaunchAgent，环境变量才会生效。

## 停止与卸载自动启动

卸载 LaunchAgent 并停止其管理的程序：

```sh
launchctl bootout "gui/$(id -u)" "$HOME/Library/LaunchAgents/com.zhijun.eye_rest_guard.plist"
```

删除自动启动配置：

```sh
rm "$HOME/Library/LaunchAgents/com.zhijun.eye_rest_guard.plist"
```

手动运行的实例可以通过控制面板退出，或在启动它的终端按 Ctrl+C。

## 文件说明与验证范围

| 文件 | 作用 |
| --- | --- |
| `eye_rest_guard.swift` | 完整的护眼提醒程序，保留原始源码 |
| `extras/com.zhijun.eye_rest_guard.plist` | 自动启动配置模板，安装时填入可执行文件绝对路径 |
| `extras/control.applescript` | 控制面板启动器，可编译为 macOS App |

本次整理验证了 Swift 源码编译、plist 格式和 AppleScript 编译，没有自动安装或启动程序。

多显示器覆盖仍需运行验证：当前源码为每个屏幕创建遮罩窗口，但只对首个窗口调用了 `makeKeyAndOrderFront`。
