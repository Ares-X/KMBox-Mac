# KMBox Mac

> **非官方版本（Unofficial）**：独立开发，与 KMBox、DFRobot 或 MicroPython 官方没有隶属或背书关系。

**原生 macOS KMBox 工作台：网络键鼠控制、设备配置与监控、MicroPython 脚本开发。**

[English](README.en.md) · [使用指南](docs/USAGE.md) · [兼容性](docs/COMPATIBILITY.md) · [协议](docs/PROTOCOL.md) · [来源与致谢](SOURCES.md)

使用 SwiftUI / AppKit 和 macOS 系统接口实现，包含桌面应用、`kmctl` 命令行及可复用的 `KMBoxCore`。没有第三方 Swift 包、Windows DLL、Qt 或 Python GUI 依赖。当前版本 **1.3.2**，界面以中文为主。

uPyCraft 提供了脚本工作流参考；本项目不是把 Windows uPyCraft 可执行文件重新打包为 Mac 应用。

## 实际应用截图

以下为 **1.3.1（build 8）在 macOS 上实际运行的窗口截图**，使用默认示例脚本，未连接 KMBox、未启动视频预览。截图保留了 1.3.1 的界面；1.3.2 已将轨迹面板移至配置页顶部。截图不代表设备功能已通过实机验收。

**网络控制**：设备连接、相对/自动/Bézier 移动、鼠标按键与 HID 键盘控制。

![KMBox Mac 网络控制实际界面，设备未连接](docs/images/network-control.jpg)

<details>
<summary>展开查看 Python 工作台、配置与监控、采集与截图</summary>

**Python 工作台**：本地/板载文件入口、语法高亮编辑器、上传与运行、MicroPython 终端。图中为应用自带的 `hello_nb.py`，未连接串口或执行脚本。

![KMBox Mac Python 工作台实际界面，显示自带示例脚本](docs/images/python-workbench.jpg)

**配置与监控**：外设查询、应答统计和配置读取状态。未读取的固件、算法和阈值会明确显示为未知。

![KMBox Mac 配置与监控实际界面，尚未读取设备配置](docs/images/configuration-monitoring.jpg)

**采集与截图**：从 Mac 实际视频设备枚举格式和帧率。图中已识别内置摄像头，但预览未启动，黑色区域没有视频输入。

![KMBox Mac 采集与截图实际界面，视频预览未启动](docs/images/capture.jpg)

</details>

## 功能与验证状态

下列能力均已有桌面实现。**“本机验证”包括代码测试、回环 UDP / PTY 模拟设备和 GUI 操作，不等于真实盒子验证；收到 ACK 也不证明 OTG 已输出或配置已保存。**

| 功能 | 可以做什么 | 已验证与待验证范围 |
| --- | --- | --- |
| 网络键鼠控制 | 相对移动、五键鼠标、滚轮、HID 键盘、组合键、保持与释放 | 本机报文与状态测试通过；**NB 基础握手、W/S/A/D 输出已有人工实测**，其余键鼠动作未逐项完成实机验收 |
| 自动 / Bézier 移动 | 设置位移、时长和控制点，发送单次移动命令 | GUI 与回环报文核对通过；**实际运动轨迹、时序待实机验证**，此功能不读写 NB AI 算法 |
| 设备配置 | 外设信息、解析模式写入并回读；原 Net 的 IP/端口、VID/PID、曲线、工作模式与重启接口 | 本机协议和回读流程通过；NB 外设查询曾返回全零，**有效查询、配置生效/掉电保存、重启待逐型号验收** |
| 键鼠监控与轨迹 | 接收报告、绘制设备上报与本程序请求轨迹、导出带时间戳的原始 JSONL | 本机收包、绘图与导出验证通过；**NB 已实测收到真实鼠标位移报告**；三路来源未分离，修正后采样位置及第三方输入仍待验证 |
| 诊断与厂商适配 | 匹配 ACK 的 RTT/超时统计、ICMP Ping、芯片 ID、厂商解析建议与反馈 | 本机通信及失败路径通过；**真实芯片 ID 和厂商在线服务未验收**，RTT 不等于 OTG 输入延迟 |
| 本机 Python 编辑 | 多标签、行号/高亮、缩进、查找替换、撤销重做、语法检查、草稿恢复和工作区 | 本机编辑、文件操作和主要 GUI 流程已验证；离线语法检查使用本机 Python 3，不能证明设备模块可用 |
| B 串口与板载文件 | raw REPL、终端输入输出、运行/停止、上传下载、校验与备份、启动脚本入口生成 | PTY 模拟设备和文件流程通过；**真实 MicroPython、板载文件完整流程及自启待实机验证** |
| 采集与截图 | AVFoundation 预览、设备格式/帧率、PNG/JPEG/BMP/TIFF、设备左键按下截图 | 已验证设备枚举/刷新、图像编码和触发逻辑；**真实采集卡预览到按键截图的完整链路未验收** |
| NB 固件下载服务 | 检查 `.cpio`、显示指纹、提供 HTTP 下载，由盒子升级页发起更新 | CPIO 与本机完整下载通过；**盒子下载、Flash 写入和重启未验收**，下载完成不等于刷写成功 |
| 命令行与开发接口 | `kmctl` 和可复用的原生 Swift `KMBoxCore`，与 GUI 共用通信实现 | 1.3.2 构建通过 **75 项 Swift 测试、83 个 CLI 场景**；这两项统计不代表硬件覆盖率 |

逐项入口见 [完整功能表](docs/FEATURES.md)，测试条件与实机记录见 [验证说明](docs/VALIDATION.md)。

## 先区分两条连接

| 任务 | 连接 |
| --- | --- |
| NB / Net 网络键鼠控制 | USB 网络接口或以太网，使用 Net UDP；输入设备实际 IP、端口、UUID |
| NB / B Pro 的 Python、REPL 和板载文件 | B 串口，Mac 上出现对应 `/dev/cu.*`，固件启用 Python / 串口功能 |

**USB 直连出现网卡，不代表已经获得 Python REPL。** 网络和串口连接可以同时使用。当前没有通过 Net UDP 实现通用文件上传或单线网络 REPL。

Net 命令的输入输出指向盒子 **OTG 口所接电脑**。应用允许选择本机 IPv4 接口，但不会配置 Mac 网卡地址或更改路由。

## 下载应用

从 [GitHub Releases](https://github.com/Ares-X/KMBox-Mac/releases/latest) 下载 `KMBox-Mac-版本号-universal.zip`，解压后将 `KMBox Mac.app` 拖入“应用程序”。`kmctl` 命令行作为单独附件提供，校验值见同一 Release 的 `SHA256SUMS.txt`。

需要 macOS 13 或更新版本，应用和 CLI 均包含 Apple Silicon / Intel 架构。当前应用使用本地 ad-hoc 签名，**没有 Developer ID 签名或 Apple 公证**；macOS 可能拦截首次打开。也可按下方步骤从源码构建。

## 从源码构建

需要 macOS 13 或更新版本及支持 Swift 5.9+ 的 Xcode 工具链。测试工具还需要 Python 3 标准库；无需 `pip install`。最新验证环境为 Apple Silicon、macOS 27.0.1、Swift 6.4（旧版还验证过 macOS 26.6.2 / Swift 6.3.3）；最低系统版本和 Intel 物理机尚未单独验收。

在仓库根目录执行：

```bash
swift --version
swift test
bash scripts/build-app.sh
open "dist/KMBox Mac.app"
./dist/kmctl --help
```

构建脚本生成 `dist/KMBox Mac.app` 和 `dist/kmctl`，二者均包含 arm64 / x86_64。`dist/` 不纳入源码 Git；预编译应用通过 GitHub Release 附件发布。

默认启动不会自动连接设备、运行脚本或触发刷写。完整操作步骤和文件恢复方式见 [使用指南](docs/USAGE.md)。

## CLI 示例

把占位值替换为盒子实际显示的信息；多网卡时加 `--local MAC_IPV4`。

```bash
./dist/kmctl interfaces
./dist/kmctl --host DEVICE_IP --port DEVICE_PORT --uuid DEVICE_UUID connect
./dist/kmctl --host DEVICE_IP --port DEVICE_PORT --uuid DEVICE_UUID move 10 0
./dist/kmctl --host DEVICE_IP --port DEVICE_PORT --uuid DEVICE_UUID auto-move 100 0 500 --stats
./dist/kmctl --host DEVICE_IP --port DEVICE_PORT --uuid DEVICE_UUID bezier-move 100 0 500 0 50 100 50
./dist/kmctl --host DEVICE_IP --port DEVICE_PORT --uuid DEVICE_UUID monitor 10 6688 --monitor-output ./monitor.jsonl
./dist/kmctl --serial /dev/cu.DEVICE ls
./dist/kmctl --serial /dev/cu.DEVICE run example.py
```

`--stats` 在 stderr 输出事务统计 JSON；`info` / `monitor` 的结果 JSON 在 stdout。`--monitor-output` 只创建新文件，取消后保留已接收日志。串口连接会中断盒内当前脚本并进入 raw REPL。

## 尚未实现的能力

- **NB AI 算法目录、当前算法和移动阈值的网络读写**：尚无已确认的接口；原 Net 四项曲线菜单不代表 NB 全部算法。
- **人工输入 / 程序输入 / 盒子修正后的三路实际轨迹**：已知报告没有三路来源标签；目前只绘制收到的单份报告与本应用已获 ACK 的请求终点，不对单路报告推断来源或虚构另外两路。
- **单线网络 Python / WebREPL / 网络板载文件管理**：脚本和文件工作台仍使用 B 串口。
- **输入屏蔽、LCD 图像等 SDK 专项，以及非 NB 型号的专用刷机工具**：尚未集成；本程序不是整个 kmNet SDK 或旧 uPyCraft 所有板型烧录器的替代品。
- **自动识别型号和完整固件配置**：当前型号由用户选择，不能从握手成功推断固件或算法支持。

## 型号与平台验证范围

目前 **NB 基础握手、部分键盘输出和鼠标位移上报**有实机观察。Net、NetPro 8K、NVideo、B+ / B Pro、AI 的入口依据公开协议/文档开放，**尚未完成各型号硬件验收**；A 型号仅展示能力边界，控制接口未实现。NB HTTP 更新服务不能作为其他型号的刷机工具。详见 [兼容性矩阵](docs/COMPATIBILITY.md)。

macOS 本机编译、签名及主要页面操作已验证，Intel CLI 在 Rosetta 下可启动；**最低 macOS 版本和 Intel 物理机未独立验收**。固件页的 GUI 自动化复测曾因界面工具自身崩溃而未完成，不能据此将该页的完整交互记为通过。

## 数据与外部服务

设备地址、编辑草稿等保存在本机。监控导出可能含键盘输入和设备信息，提交 Issue 前应检查并脱敏。

“厂商在线适配”仅在点击相应按钮时向原上位机使用的 `47.75.195.35:5002` 发送外设标识、解析模式或测试结果；普通 TCP，实际服务可用性未验证。连接设备不会自动联系该服务。相机预览需 macOS 相机权限；固件 HTTP 服务只在手动启动时监听。详见 [使用指南的数据说明](docs/USAGE.md#数据与权限)。

## 仓库结构

```text
Sources/KMBoxCore/       Net UDP、串口 REPL、文件和固件服务
Sources/KMBoxApp/        SwiftUI / AppKit 桌面应用
Sources/kmctl/           命令行入口
Tests/KMBoxCoreTests/    协议、状态、文件、UDP / PTY 集成测试
scripts/                通用构建与原创图标生成
Resources/              应用元数据
tools/                 本机模拟器与 CLI / HTTP 验证工具
docs/                  使用、协议、兼容性和验证文档
```

`research/`、`artifacts/`、`dist/` 仅供本地研究和构建，默认不跟踪。公开仓库不携带厂商固件、Windows 工具、下载的第三方仓库、设备日志或个人会话。来源链接和固定版本记录在 [SOURCES.md](SOURCES.md) 与 [来源清单](docs/sources.json)。

## 参与和许可

提交问题或改动前请阅读 [CONTRIBUTING.md](CONTRIBUTING.md)。版本变化见 [CHANGELOG.md](CHANGELOG.md)，维护和发布步骤见 [发布指南](docs/RELEASING.md)。

本项目自有代码与文档使用 [MIT License](LICENSE)。参考项目和厂商资料仍遵循其各自许可，来源引用不代表它们被重新授权为 MIT。
