# KMBox Mac

> **非官方版本（Unofficial）**：社区独立开发，与 KMBox、DFRobot 或 MicroPython 官方没有隶属或背书关系。

**原生 macOS KMBox 工作台：网络键鼠控制、设备配置与监控、MicroPython 脚本开发。**

[English](README.en.md) · [使用指南](docs/USAGE.md) · [兼容性](docs/COMPATIBILITY.md) · [协议](docs/PROTOCOL.md) · [来源与致谢](SOURCES.md)

使用 SwiftUI / AppKit 和 macOS 系统接口实现，包含桌面应用、`kmctl` 命令行及可复用的 `KMBoxCore`。没有第三方 Swift 包、Windows DLL、Qt 或 Python GUI 依赖。当前版本 **1.3.1**，界面以中文为主。

本项目为独立实现，与 KMBox、DFRobot 或 MicroPython 官方没有隶属或背书关系。uPyCraft 提供了脚本工作流参考；本项目不是把 Windows uPyCraft 可执行文件重新打包为 Mac 应用。

## 可以做什么

| 功能 | 入口与范围 |
| --- | --- |
| 网络键鼠控制 | 相对移动、自动移动、Bézier 控制点、五键鼠标、滚轮、HID 键盘、组合键、保持与释放 |
| 设备配置 | 外设信息、解析模式写入并回读；原 Net 的 IP/端口、VID/PID、曲线、工作模式与重启接口 |
| 监控与诊断 | 键鼠报告、轨迹、带接收时间的原始 JSONL、匹配 ACK 的 RTT 统计、ICMP Ping、芯片 ID |
| Python 工作台 | 多标签编辑、语法检查、终端、板载文件管理、上传校验与备份、运行/停止、启动脚本入口 |
| 采集与截图 | AVFoundation 视频预览、设备格式/帧率、PNG/JPEG/BMP/TIFF、设备左键按下截图 |
| NB 固件下载服务 | 检查 `.cpio` 并提供 HTTP 下载，由盒子升级页发起下载与刷写 |
| 命令行与开发接口 | `kmctl` 和原生 Swift `KMBoxCore`，与 GUI 共用通信实现 |

详细对应关系见 [功能表](docs/FEATURES.md)。

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

需要 macOS 13 或更新版本及支持 Swift 5.9+ 的 Xcode 工具链。测试工具还需要 Python 3 标准库；无需 `pip install`。已验证的开发环境为 Apple Silicon、macOS 26.6.2、Swift 6.3.3；最低系统版本和 Intel 物理机尚未单独验收。

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

## 当前限制与验证程度

- **ACK 不是实际键鼠输出验收。** 原生代码、回环 UDP / PTY 测试、GUI 操作及真实盒子行为分别记录于 [验证说明](docs/VALIDATION.md)。
- NB 已有握手及基础按键输出的人工实测记录；外设查询曾返回全零、监控曾没有报告。新自动/Bézier 命令、配置持久化、串口与固件刷写仍需对应硬件验收。
- **NB AI 算法目录、当前算法和移动阈值没有已确认的网络读写接口。** 原 Net 四项曲线菜单不代表 NB 全部算法。
- **人工输入 / 程序输入 / 盒子修正后的三路实际轨迹尚未接通。** 现有报告没有三路来源标签；本程序只绘制收到的单份报告与已获 ACK 的请求终点。
- 型号选择依据公开文档分流能力，不会自动识别型号/固件，也不表示所有型号已实测。见 [兼容性矩阵](docs/COMPATIBILITY.md)。

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
