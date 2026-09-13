import Foundation

public enum DeviceModel: String, CaseIterable, Identifiable, Sendable {
    case nb = "KMBox NB"
    case net = "KMBox Net"
    case netPro = "KMBox NetPro 8K"
    case nvideo = "KMBox NVideo"
    case bPro = "KMBox B+ / B Pro"
    case a = "KMBox A"
    case ai = "KMBox AI"
    public var id: String { rawValue }
    public var supportsNet: Bool { [.nb, .net, .netPro, .nvideo, .ai].contains(self) }
    public var supportsSerialREPL: Bool { [.nb, .bPro].contains(self) }
    public var supportsFirmwareHosting: Bool { self == .nb }
    public var compatibility: String {
        switch self {
        case .nb: return "Net 网络键鼠 + B 串口 Python；新增官方 HTTP 固件下载服务。"
        case .net: return "可复用 Net 网络键鼠协议；没有板载 MicroPython 脚本功能。"
        case .netPro: return "官网声明兼容 Net 功能；可使用网络键鼠控制，专有配置与 8K 吞吐尚未验证。"
        case .nvideo: return "键鼠 API 与 Net 一致；Mac 可预览系统识别的视频采集设备，NVideo 专有视频及 Xbox 转换未验证。"
        case .bPro: return "可复用串口 MicroPython 工作台；无 Net UDP。波特率需与设备一致。"
        case .a: return "A 使用独立 USB HID 厂商报告协议；当前程序尚无 A 传输后端，不能用 Net 或 REPL 替代。"
        case .ai: return "官网声明支持 Net 无线协议；须启用相应服务并核实连接参数。板载 Linux / ARM SDK 与 Python 工作台不同。"
        }
    }
    public var firmwareNote: String {
        switch self {
        case .nb: return "提供 /kmboxNB.cpio，盒子从 Mac 的 TCP 80 端口主动下载；最终写入与重启由盒子完成。"
        case .net, .nvideo: return "官方使用独立 USB IAP 升级器。已取得 WCH IAP 示例源码，但实际 bootloader、地址映射与硬件匹配仍需验证；本程序未开放写入。"
        case .netPro: return "官方使用专用升级模式、驱动和 .npro 包；不能按 NB CPIO 或普通 Net .bin 写入。"
        case .bPro: return "官网通过 uPyCraft 升级 .bin；本次样本已验证为 ESP32 镜像，可评估接入 esptool，设备 Flash 与激活状态仍待核实。2024-08-31 前未激活的盒子受官方升级限制。"
        case .a: return "官方升级使用 Mouse 口与板内按钮 / 短接点，.A 固件；控制用 HID 协议不能直接当作 bootloader 协议。"
        case .ai: return "Linux 开发板系统升级与 NB / Net 固件不通用，官网固件入口仍标为工程中。"
        }
    }
    public var firmwareURL: URL {
        let name: String
        switch self {
        case .nb: name = "NB_firmware.html"
        case .net: name = "Net_firmware.html"
        case .netPro: name = "NetPro8K_firmware.html"
        case .nvideo: name = "NVideo_firmware.html"
        case .bPro: name = "BPro_firmware.html"
        case .a: name = "A_firmware.html"
        case .ai: name = "documents.html"
        }
        return URL(string: "https://www.kmbox.top/" + name)!
    }
}
