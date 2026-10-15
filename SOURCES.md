# 来源、许可与致谢

本项目使用 Swift/SwiftUI/AppKit 与系统网络、串口、AVFoundation 接口独立实现。参考资料用于核对协议、行为和工作流；以下列出的第三方源文件、Windows SDK/DLL/PYD、固件、图标和安装包均不纳入 Git 或应用分发。根目录 [MIT 许可证](LICENSE) 只适用于本项目自有材料。

这是一份来源关系记录，不是第三方再分发授权。许可证观察针对所列固定版本；没有发现许可证文件不代表已确认全部权利状态。未来如直接纳入第三方代码，应重新检查对应许可并保留其要求的声明。完整固定提交、下载指纹与引用用途见 [sources.json](docs/sources.json)。

## 主要依据

| 来源 | 固定版本 / 观察 | 对应实现 |
| --- | --- | --- |
| [DFRobot/uPyCraft_src](https://github.com/DFRobot/uPyCraft_src/tree/68dfc449ee1af7f4bdb0ba8a9a127ec890935d3b) | `68dfc449ee1af7f4bdb0ba8a9a127ec890935d3b`；完整树未见 LICENSE/COPYING/COPYRIGHT 文件 | Python 编辑、B 串口与板载文件工作流，未分发原 IDE 或代码 |
| [kvmaibox/kmboxnet](https://github.com/kvmaibox/kmboxnet/tree/9b62283c6271e8e594f3b97986fed291deb4318f) | `9b62283c6271e8e594f3b97986fed291deb4318f`；完整树未见许可证文件 | `NetProtocol`、`NetClient`、`NetDiagnostics` 的报文布局与字节序 |
| [MicroPython pyboard.py](https://github.com/micropython/micropython/blob/v1.13/tools/pyboard.py) / [MIT 许可](https://github.com/micropython/micropython/blob/v1.13/LICENSE) | `v1.13`；Copyright 2013–2020 Damien P. George | raw REPL framing、Ctrl-C/终端行为对照；未包含 MicroPython 运行时或 pyboard 工具 |
| [官方 Net 调试工具](https://www.kmbox.top/tools/NetRelease.zip) | 20260904，另对照旧版 20251106；下载指纹见来源清单 | 原 Net 曲线菜单、外设解析、监控格式、芯片 ID 和在线适配行为的静态核对；2026-10-15 复核单路 XY 累计及前 20 字节读取；未执行或分发 EXE |
| [Net 用户手册](https://www.kmbox.top/wiki_doc/kmboxNet/site/) | 2026-10-15 核对“如何打开轨迹显示功能” | 官方最终运动轨迹及第三方软件输入语义；不据此断言 NB 三路分离已实现 |
| [KMBox 文档入口](https://www.kmbox.top/documents.html) / [NB 文档](https://www.kmbox.top/wiki_doc/kmboxNB/site/) | 文档按 2026-09-13 的研究记录使用，官网可能更新 | 型号分流、NB 接线/Python、设备主动 HTTP 更新、三路轨迹边界 |

官方 [C++ 实现](https://github.com/kvmaibox/kmboxnet/blob/9b62283c6271e8e594f3b97986fed291deb4318f/c%2B%2B_demo/NetConfig/kmboxNet.cpp) 与 [协议头](https://github.com/kvmaibox/kmboxnet/blob/9b62283c6271e8e594f3b97986fed291deb4318f/c%2B%2B_demo/NetConfig/kmboxNet.h) 是 Net 报文的主要基准。不同第三方连接器不一致时，本项目保留该基准和对应回环报文测试，而不是拼接各库的 setter。

## GitHub 连接器对照

下表全部为参考用途，不是运行依赖。新功能采用原生 Swift 实现；这里的 MIT/未见许可描述属于参考仓库，不能与本项目许可证混淆。

| 项目 | 对照提交 | 许可观察 | 参考与处理 |
| --- | --- | --- | --- |
| [andyless/kmbox-universal](https://github.com/andyless/kmbox-universal/tree/db120b549c0c6fe5eaf5b94403ee178f3f4d208f) | `db120b549c0c` | MIT | 自动/Bézier 报文及监控生命周期对照；未采用其配置字段和只停止本机接收的差异实现。 |
| [OceanTw/KMNet.java](https://github.com/OceanTw/KMNet.java/tree/095ec9ad057e952f28ab8f2be6e1c078dba79ac7) | `095ec9ad057e` | 固定版本未见许可证 | 键鼠事件组织方式参考；未直接纳入事件库。 |
| [uve192/KMBox.NET](https://github.com/uve192/KMBox.NET/tree/5a5aea9b0d92839e28893acd59a6eaf68dcb25e8) | `5a5aea9b0d92` | MIT | 20 字节报告及控制点结构的交叉核对。 |
| [yuta6/kmbox-net-native-client](https://github.com/yuta6/kmbox-net-native-client/tree/ea956862c64ef48eefb876953e09e6e75ea3feb4) | `ea956862c64e` | MIT | 跨平台 UDP 编码、监控时间戳和有界队列参考；不混入超时合成的零位移事件。 |
| [KuromeSama6/kmboxnet](https://github.com/KuromeSama6/kmboxnet/tree/088d66ff3fce9b5f4ce9ddcabd6b3002b2dbd338) | `088d66ff3fce` | MIT | 异步接口和公开命令范围对照。 |
| [chase-irql/CPP-KmBoxNet](https://github.com/chase-irql/CPP-KmBoxNet/tree/150c49df9eead858ecc7e1277f2d6676e1d40da4) | `150c49df9eea` | MIT | API 状态和错误表达参考；不采用无确认发送。 |
| [shengdingbox/kvmNet_python](https://github.com/shengdingbox/kvmNet_python/tree/b7c3959d4b377dd17199b1bf562a1e69900c1c59) | `b7c3959d4b37` | 仅观察到所带 pybind11 许可，整体未确认 | 平台兼容性核对；未使用其中 Windows PYD/构建产物。 |
| [ShirokoLEET/simple-kmbox-connect](https://github.com/ShirokoLEET/simple-kmbox-connect/tree/a371cb589aee96fd8f059bc23a1d2f949504321b) | `a371cb589aee` | 固定版本未见许可证 | 最小 Net 握手/控制流程对照。 |
| [TKazer/KmBoxNetManager](https://github.com/TKazer/KmBoxNetManager/tree/51edccd40fd4cf5cd13cf1166023258f3fca83b3) | `51edccd40fd4` | 固定版本未见许可证 | 旧 Windows 客户端接口范围对照。 |
| [Linorman/kmboxNet-linux](https://github.com/Linorman/kmboxNet-linux/tree/f12199d7a22be56fd69cfddaf8ba50ba3ea0e4cb) | `f12199d7a22b` | 固定版本未见许可证 | POSIX 实现及原 Net 四项曲线参数的交叉核对。 |
| [Oein/node-kmbox](https://github.com/Oein/node-kmbox/tree/49b6049b4db35121933eeef5d396bfcf99a190be) | `49b6049b4db3` | 固定版本未见许可证 | B Pro 串口辅助函数流程对照；未使用上传辅助库实现。 |
| [Krzanowski-Ambroise/kmbox-net-tester](https://github.com/Krzanowski-Ambroise/kmbox-net-tester/tree/50e43cb8513776f965665368747594e249cdd1e1) | `50e43cb85137` | 固定版本未见许可证 | 诊断统计呈现参考；本项目统计匹配事务，不用重复握手或任意 UDP 包作为延迟测量。 |

采用的方向包括自动/Bézier 单次命令、原始监控接收时间和被动应答统计。未照搬不匹配官方字段的配置写法、空闲合成鼠标报告、无应答校验的测量或监控只停止本机不通知设备的流程。额外连接器也没有提供经本项目确认的 NB AI/阈值目录或三路真实数据接口。

## 平台、标准与资产

- [Apple SwiftUI](https://developer.apple.com/documentation/swiftui)、[AppKit](https://developer.apple.com/documentation/appkit)、[AVFoundation](https://developer.apple.com/documentation/avfoundation)：系统 API，应用不随包复制 Apple SDK。
- [Apple XNU 网络绑定实现](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/netinet/in_pcb.c)：macOS 低端口/接口绑定行为参考，不复制内核代码。
- [MicroPython 内置函数](https://docs.micropython.org/en/v1.13/library/builtins.html)、[PEP 263](https://peps.python.org/pep-0263/)：设备语法检查与 Python 源码编码声明参考。
- 应用图标由本项目 `scripts/make-icon.swift` 绘制。界面符号调用 macOS 系统符号；未复制厂商品牌图标、网页图片或截图。
- Python 模拟器和 CPIO/UDP 测试数据由本项目生成；固定 UUID、十六进制和地址是测试/协议样例，不是发布实际设备会话。

## 厂商文件与名称

KMBox 固件、Net 上位机、uPyCraft Windows 包和其他型号升级器只保留在被忽略的本地研究目录，不编译或分发。固件需使用者自行从[厂商页面](https://www.kmbox.top/NB_firmware.html)取得，项目许可证不授权再分发这些文件。

KMBox、uPyCraft、MicroPython 等名称归其各自权利人，用于说明兼容性和来源，不表示官方维护或背书。本项目的 MIT 文本采用 [OSI 标准模板](https://opensource.org/license/mit)。
