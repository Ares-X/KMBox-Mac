# 型号与固件兼容性

“开放入口”表示桌面实现和公开协议/文档存在依据，不表示已完成该型号实测。选择型号不会自动识别当前硬件或固件版本。具体查询、配置、报告和时序仍受固件影响。

| 型号 | 本版入口 | 固件更新 | 验证边界 |
| --- | --- | --- | --- |
| NB | Net UDP 控制、B 串口 Python/文件 | 官方通用 HTTP 下载服务 | 基础握手/按键、鼠标位移上报已有实测；定时移动、三路来源、串口及完整刷写待验收 |
| Net | 通用 Net UDP 控制/配置 | 未实现 USB IAP | 协议和模拟器核对，未作型号完整硬件验收 |
| NetPro 8K | 依据官网兼容声明开放通用 Net 控制 | 未实现 `.npro` 升级 | 8K 吞吐、专有扩展未验证 |
| NVideo | 依据官网声明开放通用 Net 控制 | 未实现专用升级 | 盒子的专有视频功能不等于本机 AVFoundation 采集 |
| B+ / B Pro | 兼容串口 Python 工作台 | 未集成 ESP32 烧录 | 不是 Net UDP；真实 REPL 与自启需按固件验证 |
| A | 展示型号边界，控制入口未实现 | 未实现 HID/bootloader | 独立 HID 协议，不能复用 Net socket |
| AI | 已启用 Net 服务时的通用控制入口 | 未实现 Linux 系统更新 | 不加载板端 ARM `.so`；与 NB 的“AI 轨迹算法”不是同一概念 |

依据：[NB](https://www.kmbox.top/wiki_doc/kmboxNB/site/)、[Net](https://www.kmbox.top/wiki_doc/kmboxNet/site/)、[NetPro 8K](https://www.kmbox.top/wiki_doc/kmboxNetPro8K/site/)、[NVideo](https://www.kmbox.top/wiki_doc/nvideo/site/)、[B](https://www.kmbox.top/wiki_doc/kmboxB/site/)、[A](https://www.kmbox.top/wiki_doc/kmboxA/site/)、[AI Net 设置](https://www.kmbox.top/wiki_doc/kmboxAI/site/start/#_23)。资料会变化，采用实际型号文档和固件说明。

## NB 固件路径

本版服务提供 `/kmboxNB.cpio`，由 NB 升级页向 Mac 发 HTTP GET，设备自己写入并重启。这个服务不提供 bootloader 恢复，也不能代替其他型号的固件工具。不会把 `.bin`、`.npro`、`.A` 或板端系统镜像作为 NB 包刷写。

镜像检查要求 CPIO 结构与所需成员；2026-09-03 官方样本已知的校验差异只按完整文件 SHA-256 限定处理并提示，不是任意镜像放行。该检查不验证厂商数字签名，也不识别用户当前硬件版本。服务端下载完成不表示 Flash 成功。参见 [NB 官方升级](https://www.kmbox.top/wiki_doc/kmboxNB/site/03-update/) 和 [下载页](https://www.kmbox.top/NB_firmware.html)。

## 曲线与配置发现

- 自动/Bézier 移动是单次指令，并非更改盒内曲线算法。
- 原 Net 上位机菜单编号为 Bezier、Arm、RT-Bezier、RT-Arm；本版只保留该兼容接口，不能推导 NB AI 编号。
- NB 固件/文档中有 AI 轨迹和移动阈值，但尚未确认可供 Mac 使用的算法目录、当前值和阈值网络读取命令。
- NB 屏幕的三路轨迹包含人工、软件与修正输出；修正受程序输入超过阈值的条件影响。已知 Net 20 字节报告不带三路来源标签，不能据此画出三路真实结果。[官方轨迹说明](https://www.kmbox.top/wiki_doc/kmboxNB/site/022-Trace/)

完整状态见 [验证说明](VALIDATION.md)，各功能入口见 [功能表](FEATURES.md)。
