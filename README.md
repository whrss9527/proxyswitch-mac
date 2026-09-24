# ProxySwitch for Mac

macOS 菜单栏里的代理开关：一键切换系统代理、环境变量、git 和 npm 的代理设置，多套配置随时切换。原生 Swift 写成，界面是毛玻璃风格，在 macOS 26 上会用系统的 Liquid Glass。

Windows 版在 [proxyswitch](https://github.com/whrss9527/proxyswitch)，两边功能各自演进。

<p align="center"><img src="docs/panel.jpg" width="360" alt="菜单栏面板"></p>
<p align="center"><img src="docs/settings.jpg" width="720" alt="设置窗口"></p>

## 功能

- **内置节点代理**：填一个机场的订阅地址，节点就出现在面板里，可以选节点、自动选择延迟最低的、一键测速；支持全局代理和按规则分流，规则可以直接用 [johnshall 的小火箭规则](https://github.com/johnshall/Shadowrocket-ADBlock-Rules-Forever)（黑名单、白名单、去广告等预设）或任何小火箭 / Surge / Clash 格式的规则地址。不用再装 Clash 或小火箭。
- **菜单栏面板**：点图标弹出，大开关、配置列表和每个配置的延迟、复制在当前终端里用代理的命令、一键测速、进设置。右键或 Control + 点击是简洁菜单。
- **多套配置**：HTTP / SOCKS5 / PAC 三种。每套可以选生效范围：系统代理、环境变量、git、npm。
- **系统代理**：读取和监听用 SystemConfiguration，别的程序（Clash、Surge、公司脚本）改了代理会立刻反映在图标上，可以一键保存成配置。写入用 `networksetup`。
- **环境变量**：写到 launchd（`launchctl setenv`），之后新开的终端和程序都能读到；已经打开的终端用面板里复制的 `export` 命令。
- **测速与健康检查**：经代理实际访问测速地址测延迟（PAC 由系统执行，和浏览器一致）；开启期间定期检查代理端口，连不上时提醒。
- **自动检测**：找出本机正在运行的代理软件监听的端口，确认能用后一键添加。
- **全局快捷键**：默认 ⌃⌥P 开关代理，可以在设置里录制新的。
- **登录时启动**：系统设置的「登录项」里可以看到和关闭。
- **命令**：`open proxyswitch://toggle`、`proxyswitch://on`、`proxyswitch://off`、`proxyswitch://use?name=配置名`、`proxyswitch://settings`、`proxyswitch://update`，可以接快捷指令和脚本。
- **iCloud 同步**：打开后代理配置和设置通过 iCloud 云盘（`iCloud 云盘/ProxySwitch/config.json`）在多台 Mac 之间同步，几秒内生效；另一台 Mac 开启时可以选用 iCloud 的、用本机的或合并，两边同时改以改动时间晚的为准。
- **检查更新与一键更新**：启动后和每 6 小时检查一次 GitHub 上的新版本（可以关掉），有新版本时通知、面板里出现更新条。点「更新」会下载 zip、比对 SHA-256、就地替换 `ProxySwitch.app` 并自动重新启动；装在「应用程序」里的标准账户会弹一次系统授权对话框。

## 内置节点代理

1. 设置 → 节点与订阅，粘上机场给的订阅地址点「添加」。内核会下载解析，配置列表里自动多一条「节点代理」。
2. 面板里开关「节点代理」就是开关它：开启后系统代理指向 `127.0.0.1:7890`（HTTP 和 SOCKS 同一个端口）。节点卡片里可以选节点、自动选择、测速、切换全局 / 规则。
3. 规则分流的来源可以选内置的「国内直连」、johnshall 的几套小火箭规则，或者填自己的规则地址。小火箭 `.conf` 里的 `[Rule]` 段会转成内核规则：`DOMAIN-SUFFIX`、`DOMAIN-KEYWORD`、`IP-CIDR`、`GEOIP`、`RULE-SET`（下载后内联）、`FINAL` 都支持，`USER-AGENT`、`URL-REGEX` 这类内核不支持的会跳过；`Proxy` 类策略走面板里选中的节点。
4. 内核是 [mihomo](https://github.com/MetaCubeX/mihomo)（Clash Meta，GPL-3.0），以独立程序的形式打包在 `ProxySwitch.app/Contents/MacOS/mihomo`，只监听本机端口，配置在 `~/Library/Application Support/ProxySwitch/core/`。GeoIP 数据来自 [MetaCubeX/meta-rules-dat](https://github.com/MetaCubeX/meta-rules-dat)。
5. 不支持 TUN 模式：只有走系统代理（或环境变量）的程序会经过它，和小火箭 Mac 版的默认行为一样。

## 安装

1. 在 [Releases](../../releases) 下载 `ProxySwitch-macos.zip`，解压后把 `ProxySwitch.app` 拖到「应用程序」。
2. 程序没有 Apple 开发者签名，第一次打开会被系统拦下：在 `ProxySwitch.app` 上右键 → 打开 → 再点「打开」；或者在终端运行 `xattr -dr com.apple.quarantine /Applications/ProxySwitch.app`。
3. 需要 macOS 14 或更新版本。
4. 之后的版本在程序里更新：有新版本时面板里会出现更新条，点「更新」就行；也可以在「关于」页手动检查。请把程序放在「应用程序」里再更新，直接在下载文件夹里打开的程序被系统放在只读的临时位置，没法就地替换。

## 权限说明

- 修改系统代理需要**管理员账户**。标准账户会弹出系统的授权对话框，输入一次管理员密码。
- iCloud 同步用的是 iCloud 云盘里的普通文件夹（没有开发者签名拿不到 iCloud 的 entitlement），第一次开启时系统可能会询问是否允许访问 iCloud 云盘。
- 全局快捷键用 Carbon 的热键接口，不需要辅助功能权限。
- 通知需要在第一次弹出时允许。

## 文件位置

配置、状态和日志都在 `~/Library/Application Support/ProxySwitch/`：`config.json`、`state.json`、`proxyswitch.log`。诊断页里可以直接打开这个目录。

## 开发

需要 Xcode 16 或更新版本（用 Xcode 26 编译才有 Liquid Glass）。

```bash
swift build                          # 编译
swift test                           # 单元测试（纯逻辑：命令生成、状态解析、配置读写……）
VERSION=0.1.0 Scripts/build-app.sh   # 组装通用二进制的 dist/ProxySwitch.app 和 zip，ad-hoc 签名
```

代码结构：

| 目录 | 内容 |
| --- | --- |
| `Sources/ProxySwitch/App` | 入口、`AppState`（配置、状态、开关逻辑） |
| `Sources/ProxySwitch/Models` | 配置、系统代理快照、networksetup 命令的生成 |
| `Sources/ProxySwitch/System` | 系统代理、环境变量、git / npm、测速、快捷键、登录项、通知、URL 命令、更新、iCloud 文件、内核进程与 API、规则转换 |
| `Sources/ProxySwitch/UI` | 菜单栏图标与面板、设置窗口各页、毛玻璃样式、快捷键录制 |
| `Tests` | XCTest |
| `Scripts/build-app.sh` | 组装 .app（下载 mihomo 合成通用二进制、GeoIP 数据库）、签名、打 zip |
| `Resources` | Info.plist、图标 |

推送代码时 GitHub Actions 会在 macOS 上编译、测试、打包并启动一次截图，然后用本地 HTTP 服务器假装发布一个 9.9.9 版本，走一遍下载、校验、替换、重新启动的完整更新流程；推送 `v*` 标签会自动打包并发布 Release。

本机调试更新流程时可以把环境变量 `PROXYSWITCH_UPDATE_URL` 指向一个返回 GitHub releases 格式 JSON 的地址；调试 iCloud 同步时可以用 `PROXYSWITCH_SYNC_DIR` 把同步文件夹指到任意目录（见 `.github/workflows/ci.yml` 里的做法）。

## 许可证

[MIT](LICENSE)
