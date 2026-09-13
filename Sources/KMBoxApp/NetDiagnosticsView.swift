import SwiftUI
import KMBoxCore

struct NetDiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @State private var newHost = ""
    @State private var newPort = ""
    @State private var vendor = ""
    @State private var product = ""
    @State private var mouseMode = ""
    @State private var keyboardMode = ""
    @State private var curveEnabled = false
    @State private var curve = NetCurve.bezier
    @State private var strength = 50.0
    @State private var bypass = false
    @State private var monitorPort = "6688"

    private var canConfigure: Bool { model.netConnected && !model.netBusy }
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                NetConnectionView()
                if !model.netError.isEmpty { MessageBanner(text: model.netError, error: true) }
                MessageBanner(text: model.diagnosticsMessage)
                HStack {
                    Button(model.pingRunning ? "停止 Ping" : "持续 ICMP Ping") { model.pingRunning ? model.stopPing() : model.startPing() }
                    Text(model.pingMessage).font(.caption).textSelection(.enabled)
                    Spacer()
                    Button("读取芯片 ID") { model.readChipID() }.disabled(!canConfigure)
                }
                statisticsPanel
                configurationStatusPanel
                peripheralPanel
                monitorPanel
                HStack(alignment: .top, spacing: 18) { networkPanel; curvePanel }
                HStack(alignment: .top, spacing: 18) { identityPanel; modePanel }
                MessageBanner(text: "以下输入框是待写入值。除外设解析参数外，当前协议没有已确认的设置回读接口。Net 与 NB 固件支持可能不同，写入应答不代表实际功能已验证。")
            }.padding(24)
        }
    }

    private var statisticsPanel: some View {
        Panel(title: "Net 应答统计", icon: "chart.bar") {
            let stats = model.netStatistics
            HStack {
                Text("已发送 \(stats.sent) · 匹配应答 \(stats.acknowledged) · 超时 \(stats.timeouts) · 接收错误 \(stats.receiveFailures)")
                Spacer()
                Button("清空统计") { model.clearNetStatistics() }.disabled(model.netBusy)
            }.font(.caption)
            if let mean = stats.meanMilliseconds, let minimum = stats.minimumMilliseconds,
               let maximum = stats.maximumMilliseconds, let deviation = stats.standardDeviationMilliseconds {
                Text(String(format: "RTT 平均 %.2f · 最小 %.2f · 最大 %.2f · 标准差 %.2f ms", mean, minimum, maximum, deviation))
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            } else { Text("尚无匹配应答样本。").font(.caption).foregroundStyle(.secondary) }
            Text("忽略不匹配或不完整应答 \(stats.ignoredResponses) · 发送 \(stats.bytesSent) 字节")
                .font(.caption).foregroundStyle(.secondary)
            Text("统计本连接实际发送的命令；重新连接或清空后重新计数。RTT 包含设备处理时间，定时移动可能拉长 RTT；不是 OTG 输入延迟，超时也不等同于网络丢包。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var configurationStatusPanel: some View {
        Panel(title: "设备配置读取状态", icon: "list.bullet.rectangle") {
            Text("所选型号：\(model.deviceModel.rawValue)（手动选择，尚未由设备识别）")
            Text("固件版本、可选算法、当前曲线、移动阈值：尚未读取。")
            Text("连接后自动查询已确认的外设信息接口；目前没有确认可通过此网络连接枚举完整配置的接口。握手应答不能证明某项设置可用。")
                .font(.caption).foregroundStyle(.secondary)
            if model.deviceModel == .nb {
                Text("NB 固件资料包含 AI 轨迹与移动阈值；本机尚未读到你的盒子的算法列表和当前值。")
                    .font(.callout)
                Link("查看 NB 盒内配置说明", destination: URL(string: "https://www.kmbox.top/wiki_doc/kmboxNB/site/02-poweron/")!)
            }
        }
    }

    private var peripheralPanel: some View {
        Panel(title: "外设信息与手动解析", icon: "keyboard") {
            HStack {
                Button("读取外设信息") { model.readPeripheral() }.disabled(!canConfigure)
                if let date = model.peripheralReadAt { Text(date, style: .time).font(.caption).foregroundStyle(.secondary) }
                Spacer()
            }
            Text(model.peripheralMessage).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            if let info = model.peripheral, !info.isEmpty {
                Text(String(format: "VID %04X · PID %04X · HID %04X · Device %04X", info.vendorID, info.productID, info.hidID, info.deviceID))
                    .font(.system(.body, design: .monospaced)).textSelection(.enabled)
                Text("当前回读：鼠标解析 \(info.mouseMode) · 键盘解析 \(info.keyboardMode)").font(.callout)
                Button("将回读值填入编辑框") { mouseMode = String(info.mouseMode); keyboardMode = String(info.keyboardMode) }
            }
            HStack {
                field("鼠标解析", "0–32 / 255", $mouseMode)
                field("键盘解析", "0–32 / 255", $keyboardMode)
                Button("写入并回读") {
                    guard let mouse = Int(mouseMode), let keyboard = Int(keyboardMode) else { model.notice = "解析模式需要整数。"; return }
                    model.writeParsing(mouse: mouse, keyboard: keyboard)
                }.disabled(!canConfigure)
            }
            Text("写入前重新读取外设标识，只替换解析参数。255 表示无此类设备。")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("厂商在线适配") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("查询会向原上位机内置的 47.75.195.35:5002 发送外设 VID、PID、Device ID、HID ID。服务使用普通 TCP，联网可用性尚未验证。")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button("向厂商查询适配建议") { model.queryAdaptation() }.disabled(!canConfigure)
                        Button("应用建议并回读") { model.applyAdaptation() }.disabled(!canConfigure || model.adaptation == nil)
                    }
                    if let item = model.adaptation {
                        Text("建议：鼠标 \(item.modes.mouse) · 键盘 \(item.modes.keyboard)；厂商记录成功 \(item.successes) / 失败 \(item.failures)").font(.caption)
                    }
                    HStack {
                        Button("向厂商提交：测试正常") { model.submitAdaptation(worked: true) }
                        Button("向厂商提交：测试失败") { model.submitAdaptation(worked: false) }
                    }.disabled(!canConfigure || model.peripheral == nil || model.peripheral?.isEmpty == true)
                    Text("提交还包括当前解析模式与测试结果。仅点击提交按钮才发送反馈；请先实际测试外设。")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 10)
            }
        }
    }

    private var monitorPanel: some View {
        Panel(title: "键鼠上报与轨迹", icon: "waveform.path") {
            HStack {
                Text("本机端口").font(.caption)
                TextField("6688", text: $monitorPort).textFieldStyle(.roundedBorder).frame(width: 90)
                    .disabled(model.monitorNeedsStop || model.netBusy)
                Button("开始监控") { model.beginMonitor(port: monitorPort) }.disabled(!canConfigure || model.monitorNeedsStop)
                Button(model.monitorListening ? "停止监控" : "重试停止上报") { model.endMonitor() }.disabled(!canConfigure || !model.monitorNeedsStop)
                Spacer()
                Menu("清空") {
                    Button("设备上报轨迹") { model.deviceTrace = [.zero] }
                    Button("本程序发送轨迹") { model.sentTrace = [.zero] }
                    Button("全部轨迹") { model.clearTraces() }
                }
            }
            Text("\(model.monitorListening ? "本机接收已启动" : "接收未启动") · 有效 \(model.monitorAccepted) · 丢弃 \(model.monitorRejected)\(model.monitorRejectedLength.map { " · 未识别长度 \($0) 字节" } ?? "")")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("导出原始记录…") { model.exportMonitor() }.disabled(model.monitorCapture.records.isEmpty)
                Text("保留 \(model.monitorCapture.records.count) 条 · 缓冲淘汰 \(model.monitorCapture.discardedRecords) 条")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if !model.monitorExportMessage.isEmpty {
                Text(model.monitorExportMessage).font(.caption).textSelection(.enabled)
            }
            if let frame = model.monitorFrame {
                Text("最近上报：按钮 \(frame.buttons) · X \(frame.x) · Y \(frame.y) · 滚轮 \(frame.wheel) · 修饰键 \(frame.modifiers) · HID \(frame.keys.map(String.init).joined(separator: ", "))")
                    .font(.system(.caption, design: .monospaced)).textSelection(.enabled)
            }
            HStack(spacing: 16) {
                TraceView(title: "设备上报轨迹", points: model.deviceTrace)
                TraceView(title: "本程序发送轨迹", points: model.sentTrace)
            }
            MessageBanner(text: "三路数据尚未全部接通：现有 Net 监控报文只包含一份鼠标报告，不能区分人工、其他程序输入与盒子修正输出。本程序发送轨迹仅连接本应用已获应答的请求终点，不含定时移动的中间点；修正后轨迹没有已确认的网络读取接口，暂不绘制。NB 屏幕的“轨迹照妖镜”可显示三路数据。")
            Text("显示最近 600 个轨迹点并自动缩放。设备上报格式为 20 字节；未知格式保留原文，不绘制。JSONL 导出包含原始字节与 Mac 接收时间；保留最近 10000 条且原始数据不超过 8 MiB，重新开始监控会清空。未收到上报可能是没有输入、固件不支持，或上报目标被其他程序改写。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var networkPanel: some View {
        Panel(title: "网络设置", icon: "network") {
            field("新盒子 IP", "例如 192.168.2.188", $newHost)
            field("新端口", "1–65535", $newPort)
            Button("写入 IP 与端口") {
                model.configure("写入网络设置", resultMessage: "网络设置已收到写入应答；重新上电后使用新 IP/端口连接。当前连接信息未自动改变。") {
                    [try await model.net.setNetwork(NetNetworkSettings(host: newHost, port: newPort))]
                }
            }.disabled(!canConfigure)
            Text("写入后需重新上电。请记下新地址，协议没有当前网络配置回读。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var curvePanel: some View {
        Panel(title: "曲线配置", icon: "point.topleft.down.to.point.bottomright.curvepath") {
            Text("当前算法与参数：尚未读取").foregroundStyle(.secondary)
            if model.deviceModel == .nb {
                Text("AI 轨迹：固件中已确认存在；网络读写接口与编号尚未确认。")
                Text("修正轨迹在程序输入超过盒内阈值后产生；当前阈值未知。")
            }
            DisclosureGroup("原 Net 上位机兼容参数") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("以下四项来自 Net 调试工具 20260904，不是从当前盒子获取的算法列表，也不代表 NB 的全部算法。初始值仅为编辑草稿。")
                        .font(.caption).foregroundStyle(.secondary)
                    Toggle("启用曲线（待写入）", isOn: $curveEnabled)
                    Picker("Net 算法", selection: $curve) { ForEach(NetCurve.allCases) { Text($0.name).tag($0) } }
                    HStack { Text("曲线值 \(Int(strength))"); Slider(value: $strength, in: 0...100, step: 1) }
                    Button("写入 Net 兼容曲线参数") {
                        model.configure("写入 Net 兼容曲线", resultMessage: "已收到 Net 兼容指令应答；当前设置未回读，不能据此确认所选算法已生效。") {
                            [try await model.net.setCurve(NetCurveSettings(enabled: curveEnabled, curve: curve, strength: Int(strength)))]
                        }
                    }
                }.padding(.top, 10).disabled(!canConfigure)
            }
            Text("AI 算法不沿用 Net 选单编号。盒内阈值与此处曲线值没有已确认的对应关系。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var identityPanel: some View {
        Panel(title: "OTG USB 标识", icon: "cable.connector.horizontal") {
            HStack { field("VID（十六进制）", "1–4 位", $vendor); field("PID（十六进制）", "1–4 位", $product) }
            Button("写入 VID / PID") {
                model.configure("写入 USB 标识", resultMessage: "已收到 VID/PID 写入应答；实际枚举值需在 OTG 连接的电脑重新枚举后检查。") {
                    guard let vid = UInt16(vendor, radix: 16), let pid = UInt16(product, radix: 16) else { throw KMError.invalid("VID/PID 需要 1–4 位十六进制数，不带 0x。") }
                    return [try await model.net.setVIDPID(vendor: vid, product: pid)]
                }
            }.disabled(!canConfigure)
            Text("外设信息查询读取的是接入盒子的外设，不能用于验证此设置。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var modePanel: some View {
        Panel(title: "工作模式与重启", icon: "power") {
            Picker("待写入模式", selection: $bypass) { Text("KM").tag(false); Text("Bypass").tag(true) }
            Button("写入工作模式") {
                model.configure("写入工作模式", resultMessage: "已收到模式写入应答；需单独重启或重新上电生效，当前模式未回读。") {
                    [try await model.net.setBypass(bypass)]
                }
            }.disabled(!canConfigure)
            Divider()
            Button("立即重启盒子并断开") {
                model.configure("重启盒子", resultMessage: "已收到重启应答并关闭连接；重新上线需再次连接验证。") {
                    [try await model.net.reboot()]
                }
            }.disabled(!canConfigure)
            Text("重启前会释放本程序保持的按键并停止监控。重启指令只发送一次。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func field(_ title: String, _ hint: String, _ binding: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(hint, text: binding).textFieldStyle(.roundedBorder)
                .font(.system(.body, design: .monospaced)).disabled(model.netBusy)
        }
    }
}

private struct TraceView: View {
    let title: String
    let points: [CGPoint]
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption)
            Canvas { context, size in
                guard let first = points.first else { return }
                let minX = points.map(\.x).min() ?? 0, maxX = points.map(\.x).max() ?? 0
                let minY = points.map(\.y).min() ?? 0, maxY = points.map(\.y).max() ?? 0
                let scale = min((size.width - 24) / max(20, maxX - minX), (size.height - 24) / max(20, maxY - minY))
                func position(_ point: CGPoint) -> CGPoint {
                    CGPoint(x: size.width / 2 + (point.x - (maxX + minX) / 2) * scale,
                            y: size.height / 2 + (point.y - (maxY + minY) / 2) * scale)
                }
                var path = Path(); path.move(to: position(first))
                for point in points.dropFirst() { path.addLine(to: position(point)) }
                context.stroke(path, with: .color(accent), lineWidth: 1.5)
                let last = position(points.last ?? first)
                context.fill(Path(ellipseIn: CGRect(x: last.x - 3, y: last.y - 3, width: 6, height: 6)), with: .color(accent))
            }.frame(height: 180).background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
        }.frame(maxWidth: .infinity)
    }
}
