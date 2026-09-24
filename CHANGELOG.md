# 更新日志

## 0.1.0（未发布）

第一个版本，从 [proxyswitch](https://github.com/whrss9527/proxyswitch)（Windows 版）仓库拆出。

- 菜单栏面板：大开关、配置列表和延迟、复制终端命令、测速、进设置；右键简洁菜单。
- 配置：HTTP / SOCKS5 / PAC，生效范围可选系统代理、环境变量（launchd）、git、npm。
- 系统代理：SystemConfiguration 读取和监听，别的程序改了代理会立刻反映，可以一键保存成配置；networksetup 写入，标准账户走系统授权对话框。
- 全局快捷键（默认 ⌃⌥P）、登录时启动、代理服务器连不上时提醒、自动检测本机代理软件、`proxyswitch://` 命令。
- 设置窗口：透明标题栏、侧栏导航、配置编辑器、快捷键录制、诊断、关于；用 Xcode 26 编译时在 macOS 26 上启用 Liquid Glass。
