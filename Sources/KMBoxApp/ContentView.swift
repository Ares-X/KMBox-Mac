import SwiftUI
import AppKit
import KMBoxCore

let brandFill = Color(red: 0.07, green: 0.45, blue: 0.36)
let accent = Color(nsColor: NSColor(name: nil) { appearance in
    appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        ? NSColor(calibratedRed: 0.38, green: 0.78, blue: 0.65, alpha: 1)
        : NSColor(calibratedRed: 0.07, green: 0.45, blue: 0.36, alpha: 1)
})

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(model.page.rawValue).font(.system(size: 23, weight: .semibold))
                        Text(subtitle).font(.callout).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if model.page == .control || model.page == .diagnostics {
                        Button { model.releaseAll() } label: { Label("全部释放", systemImage: "hand.raised") }
                            .disabled(!model.netConnected).help("释放软件按下的鼠标和键盘；Command–Escape")
                    } else if model.page == .editor {
                        Button { model.newDocument() } label: { Image(systemName: "doc.badge.plus") }.help("新建文件")
                        Button { model.chooseFile() } label: { Image(systemName: "folder") }.help("打开本地文件")
                        Button { model.saveLocal() } label: { Label("保存到 Mac", systemImage: "square.and.arrow.down") }.disabled(model.activeDocument == nil)
                    } else { Button("导出记录…") { model.exportLogs() } }
                }.padding(.horizontal, 25).padding(.vertical, 21)
                Divider()
                PageHost(page: model.page, model: model)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .tint(accent)
        .alert("操作未完成", isPresented: Binding(get: { model.notice != nil }, set: { if !$0 { model.notice = nil } })) {
            Button("好") { model.notice = nil }
        } message: { Text(model.notice ?? "") }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadDataRepresentation(forTypeIdentifier: "public.file-url") { data, _ in
                    if let data, let url = URL(dataRepresentation: data, relativeTo: nil) {
                        Task { @MainActor in model.openLocal(url) }
                    }
                }
            }
            return !providers.isEmpty
        }
    }
    private var subtitle: String {
        switch model.page {
        case .control: return "通过网络连接控制 " + model.deviceModel.rawValue
        case .diagnostics: return "读取外设信息、设置设备参数和查看键鼠上报"
        case .capture: return "预览 Mac 视频采集设备，保存图像或按键触发截图"
        case .editor: return "编辑、管理和运行盒内 Python 脚本"
        case .activity: return "查看连接、操作和设备返回结果"
        case .firmware: return "按型号选择协议与固件更新方式"
        }
    }
    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 26) {
            HStack(spacing: 11) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 23, weight: .medium)).foregroundStyle(.white)
                    .frame(width: 43, height: 43).background(brandFill, in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text("KMBox").font(.system(size: 21, weight: .semibold))
                    Text("MAC WORKSPACE").font(.system(size: 9, weight: .semibold)).tracking(1.4).foregroundStyle(.secondary)
                }
            }.padding(.top, 8)
            VStack(spacing: 6) {
                ForEach(Page.allCases) { page in
                    Button { model.page = page } label: {
                        HStack(spacing: 11) {
                            Image(systemName: page.icon).font(.system(size: 15)).frame(width: 20)
                            Text(page.rawValue).font(.system(size: 13, weight: model.page == page ? .semibold : .regular)).lineLimit(1)
                            Spacer()
                        }.padding(.horizontal, 12).padding(.vertical, 11)
                            .foregroundStyle(model.page == page ? accent : .primary)
                            .background(model.page == page ? accent.opacity(0.10) : Color.clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(Rectangle())
                    }.buttonStyle(.plain)
                }
            }
            Spacer()
            VStack(alignment: .leading, spacing: 13) {
                Text("连接状态").font(.caption).foregroundStyle(.secondary)
                StatusLabel(title: "Net 网络", connected: model.netConnected, uncertain: model.netUncertain)
                StatusLabel(title: "B 串口", connected: model.boardConnected, uncertain: false)
                Divider().padding(.vertical, 3)
                Text(model.deviceModel.rawValue).font(.caption.weight(.medium))
                Text(model.deviceModel.compatibility)
                    .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
            }.padding(.horizontal, 6)
        }.padding(18).frame(width: 204).frame(maxHeight: .infinity)
    }
}

struct StatusLabel: View {
    let title: String
    let connected: Bool
    let uncertain: Bool
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(uncertain ? Color.orange : connected ? accent : Color.secondary.opacity(0.35)).frame(width: 6, height: 6)
            Text(title).font(.caption)
            Spacer()
            Text(uncertain ? "待恢复" : connected ? "已连接" : "未连接").font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }
}

struct Panel<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label(title, systemImage: icon).font(.system(size: 14, weight: .semibold))
            content
        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).stroke(.primary.opacity(0.07), lineWidth: 1))
    }
}

struct MessageBanner: View {
    let text: String
    var error = false
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: error ? "exclamationmark.circle" : "info.circle").foregroundStyle(error ? .orange : .secondary)
            Text(text).font(.caption).lineSpacing(3).textSelection(.enabled)
            Spacer(minLength: 0)
        }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
            .background(error ? Color.orange.opacity(0.08) : Color.secondary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct ControlsView: View {
    @EnvironmentObject var model: AppModel
    @State private var step: Int32 = 10
    @State private var x = "0"
    @State private var y = "0"
    @State private var movementMode = 0
    @State private var milliseconds = "500"
    @State private var x1 = "0"
    @State private var y1 = "50"
    @State private var x2 = "100"
    @State private var y2 = "50"
    @State private var key: UInt8 = 4
    @State private var control = false
    @State private var shift = false
    @State private var option = false
    @State private var command = false
    var body: some View {
        ScrollView {
            LazyVStack(spacing: 18) {
                NetConnectionView()
                if !model.netError.isEmpty { MessageBanner(text: model.netError, error: true) }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 18, alignment: .top),
                                    GridItem(.flexible(), alignment: .top)], spacing: 18) {
                    mousePanel
                    keyboardPanel
                }
                HStack {
                    Circle().fill(model.netConnected ? accent : .secondary.opacity(0.4)).frame(width: 5, height: 5)
                    Text(model.netMessage).font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    if let latency = model.latency {
                        Text(String(format: "最近应答 %.2f ms", latency)).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }.padding(.horizontal, 3)
                MessageBanner(text: "操作会发送到 NB 的 OTG 口连接的电脑。首次使用请确认被控电脑和键鼠接线；网卡出现后，还需正确配置盒子 IP、端口和 UUID。")
            }.padding(24)
        }
    }
    private func sendMovement() {
        do {
            guard let x = Int32(x), let y = Int32(y) else { throw KMError.invalid("X/Y 需要整数坐标。") }
            if movementMode == 0 { model.move(x, y) }
            else {
                guard let ms = Int(milliseconds) else { throw KMError.invalid("移动时长需要整数毫秒。") }
                var controls: NetBezierControls?
                if movementMode == 2 {
                    guard let x1 = Int32(x1), let y1 = Int32(y1), let x2 = Int32(x2), let y2 = Int32(y2) else {
                        throw KMError.invalid("Bézier 控制点需要整数坐标。")
                    }
                    controls = try NetBezierControls(x1: x1, y1: y1, x2: x2, y2: y2)
                }
                model.timedMove(x, y, milliseconds: ms, controls: controls)
            }
        } catch { model.netError = error.localizedDescription }
    }
    private var mousePanel: some View {
        Panel(title: "鼠标", icon: "computermouse") {
            HStack(spacing: 22) {
                VStack(spacing: 7) {
                    HStack(spacing: 7) { direction("arrow.up.left", -1, -1); direction("arrow.up", 0, -1); direction("arrow.up.right", 1, -1) }
                    HStack(spacing: 7) {
                        direction("arrow.left", -1, 0)
                        Image(systemName: "scope").foregroundStyle(accent).frame(width: 43, height: 38)
                            .background(accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        direction("arrow.right", 1, 0)
                    }
                    HStack(spacing: 7) { direction("arrow.down.left", -1, 1); direction("arrow.down", 0, 1); direction("arrow.down.right", 1, 1) }
                }
                VStack(alignment: .leading, spacing: 10) {
                    Text("每次移动").font(.caption).foregroundStyle(.secondary)
                    TextField("步长", value: $step, format: .number).textFieldStyle(.roundedBorder).frame(width: 75)
                    Text("相对位移单位").font(.system(size: 10)).foregroundStyle(.tertiary)
                }
            }.frame(maxWidth: .infinity).padding(.vertical, 5)
            Divider()
            HStack(spacing: 9) {
                Text("X").font(.caption).foregroundStyle(.secondary)
                TextField("X", text: $x).textFieldStyle(.roundedBorder)
                Text("Y").font(.caption).foregroundStyle(.secondary)
                TextField("Y", text: $y).textFieldStyle(.roundedBorder)
                Button("移动") { sendMovement() }.disabled(!model.canControl)
            }
            Picker("移动方式", selection: $movementMode) {
                Text("即时").tag(0); Text("自动").tag(1); Text("Bézier").tag(2)
            }.pickerStyle(.segmented)
            if movementMode != 0 {
                HStack {
                    Text("请求时长（毫秒）").font(.caption)
                    TextField("1–10000", text: $milliseconds).textFieldStyle(.roundedBorder)
                }
                if movementMode == 2 {
                    HStack {
                        Text("P1").font(.caption)
                        TextField("P1 X", text: $x1).textFieldStyle(.roundedBorder)
                        TextField("P1 Y", text: $y1).textFieldStyle(.roundedBorder)
                    }
                    HStack {
                        Text("P2").font(.caption)
                        TextField("P2 X", text: $x2).textFieldStyle(.roundedBorder)
                        TextField("P2 Y", text: $y2).textFieldStyle(.roundedBorder)
                    }
                }
                Text("X/Y 为相对终点，P1/P2 为同一起点下的相对控制点。这是单次移动请求；不修改盒内 AI 算法或阈值。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                mouseButton("左键", 1); mouseButton("中键", 4); mouseButton("右键", 2)
            }
            HStack(spacing: 8) { mouseButton("侧键 1", 8); mouseButton("侧键 2", 16) }
            HStack {
                Text("滚轮").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button { model.scroll(-1) } label: { Label("上滚", systemImage: "arrow.up") }
                Button { model.scroll(1) } label: { Label("下滚", systemImage: "arrow.down") }
            }.disabled(!model.canControl)
        }
    }
    private func direction(_ symbol: String, _ dx: Int32, _ dy: Int32) -> some View {
        Button {
            guard (1...32767).contains(step) else { model.notice = "移动步长应为 1–32767。"; return }
            model.move(dx * step, dy * step)
        } label: { Image(systemName: symbol).frame(width: 31, height: 26) }
            .buttonStyle(.bordered).disabled(!model.canControl).help("向此方向移动")
    }
    private func mouseButton(_ name: String, _ bit: Int32) -> some View {
        VStack(spacing: 9) {
            Button(name + "单击") { model.click(bit) }.frame(maxWidth: .infinity)
            Toggle("保持", isOn: Binding(get: { model.mouseButtons & bit != 0 }, set: { model.holdMouse(bit, down: $0) }))
                .toggleStyle(.checkbox).font(.caption)
        }.frame(maxWidth: .infinity).disabled(!model.canControl)
    }
    private var keyboardPanel: some View {
        Panel(title: "键盘", icon: "keyboard") {
            VStack(alignment: .leading, spacing: 10) {
                Text("选择按键").font(.caption).foregroundStyle(.secondary)
                Picker("按键", selection: $key) {
                    ForEach(HIDKey.all) { key in Text(key.name).tag(key.code) }
                }.labelsHidden().controlSize(.large)
            }
            Text("组合键").font(.caption).foregroundStyle(.secondary)
            LazyVGrid(columns: [GridItem(.flexible(), alignment: .leading), GridItem(.flexible(), alignment: .leading)], alignment: .leading, spacing: 13) {
                Toggle("⌃ Control", isOn: $control)
                Toggle("⇧ Shift", isOn: $shift)
                Toggle("⌥ Alt / Option", isOn: $option)
                Toggle("⌘ Win / Command", isOn: $command)
            }.toggleStyle(.checkbox).font(.caption)
            Button { model.tapKey(key, modifiers: modifiers) } label: {
                Label("发送按键", systemImage: "arrow.up.right").frame(maxWidth: .infinity).padding(.vertical, 3)
            }.buttonStyle(.borderedProminent).tint(brandFill).disabled(!model.canControl)
            Divider()
            HStack {
                Button("保持所选键") { model.holdKey(key, down: true) }
                Button("释放所选键") { model.holdKey(key, down: false) }
            }.disabled(!model.canControl)
            VStack(alignment: .leading, spacing: 7) {
                Text("已确认按下").font(.caption).foregroundStyle(.secondary)
                Text(model.netUncertain ? "状态不确定，请全部释放" : heldKeyNames)
                    .font(.system(size: 12, design: .monospaced)).foregroundStyle(model.netUncertain ? .orange : .secondary)
            }
            Text("按键使用 USB HID 编码；修饰键随“发送按键”自动释放。").font(.caption).foregroundStyle(.secondary).lineSpacing(3)
        }
    }
    private var modifiers: [UInt8] {
        [(control, UInt8(0xe0)), (shift, 0xe1), (option, 0xe2), (command, 0xe3)].compactMap { $0.0 ? $0.1 : nil }
    }
    private var heldKeyNames: String {
        model.heldKeys.isEmpty ? "无" : model.heldKeys.map { code in HIDKey.all.first { $0.code == code }?.name ?? String(code) }.joined(separator: "  ")
    }
}

struct ActivityView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("\(model.logs.count) 条记录").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("清空") { model.logs.removeAll() }
            }.padding(16)
            Divider()
            List(model.logs.reversed()) { entry in
                HStack(alignment: .top, spacing: 13) {
                    Text(entry.date, style: .time).font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary).frame(width: 74, alignment: .leading)
                    Image(systemName: entry.error ? "exclamationmark.circle.fill" : "checkmark.circle").foregroundStyle(entry.error ? .orange : accent)
                    Text(entry.text).font(.system(size: 12, design: .monospaced)).textSelection(.enabled)
                }.padding(.vertical, 6)
            }.listStyle(.plain)
        }
    }
}

struct NetConnectionView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        Panel(title: "设备连接", icon: "cable.connector") {
            HStack(alignment: .bottom, spacing: 12) {
                field("盒子 IP", hint: "例如 192.168.2.188", text: $model.host).frame(minWidth: 160)
                field("端口", hint: "6234", text: $model.port).frame(width: 84)
                field("UUID", hint: "屏幕上的十六进制值", text: $model.uuid).frame(minWidth: 160)
                if model.netBusy { ProgressView().controlSize(.small).frame(width: 22, height: 25) }
                Button(model.netConnected ? "断开连接" : "连接设备") {
                    if model.netConnected { model.disconnectNet() } else { model.connectNet() }
                }.buttonStyle(.borderedProminent).tint(brandFill).controlSize(.large).disabled(model.netBusy || model.firmwareActive || !model.deviceModel.supportsNet)
            }
            HStack(spacing: 10) {
                Text("本机接口").font(.caption).foregroundStyle(.secondary)
                Picker("本机接口", selection: $model.localAddress) {
                    Text("自动 · 使用系统路由").tag("")
                    ForEach(model.interfaces) { item in Text("\(item.name) · \(item.address)").tag(item.address) }
                }.labelsHidden().frame(maxWidth: 320).disabled(model.netConnected || model.netBusy)
                Button { model.refreshInterfaces() } label: { Image(systemName: "arrow.clockwise") }.help("刷新接口")
                Spacer()
                Text(model.netConnected ? "已收到设备应答" : "尚未建立连接").font(.caption).foregroundStyle(model.netConnected ? accent : .secondary)
            }
        }
    }
    private func field(_ title: String, hint: String, text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField(hint, text: text).textFieldStyle(.roundedBorder).controlSize(.large)
                .font(.system(size: 13, design: .monospaced)).disabled(model.netConnected || model.netBusy)
        }
    }
}
