import SwiftUI
import AppKit
import UniformTypeIdentifiers
import KMBoxCore

enum Page: String, CaseIterable, Identifiable {
    case control = "网络控制", diagnostics = "配置与监控", capture = "采集与截图", editor = "Python 工作台", activity = "通信记录", firmware = "固件与兼容性"
    var id: String { rawValue }
    var icon: String {
        switch self { case .control: return "computermouse"; case .diagnostics: return "slider.horizontal.3"; case .capture: return "video"; case .editor: return "chevron.left.forwardslash.chevron.right"; case .activity: return "waveform.path"; case .firmware: return "arrow.down.doc" }
    }
}

struct LogEntry: Identifiable {
    let id = UUID()
    let date = Date()
    let text: String
    let error: Bool
}

private struct SavedSession: Codable {
    var documents: [EditorDocument]
    var selected: UUID?
    var workspace: URL?
}

@MainActor
final class AppModel: ObservableObject {
    @Published var page: Page = .control
    @Published var deviceModel: DeviceModel = .nb { didSet { scheduleSave() } }
    @Published var firmware: NBFirmware?
    @Published var firmwareName = ""
    @Published var firmwareAddress = ""
    @Published var firmwareDeviceAddress = ""
    @Published var firmwareStatus: FirmwareServerStatus?
    @Published var firmwareError = ""
    let firmwareServer = FirmwareServer()
    private var firmwarePoll: Task<Void, Never>?
    var firmwareActive: Bool { firmwareStatus?.active == true }
    var canChangeModel: Bool { !netConnected && !boardConnected && !netBusy && !boardBusy && !firmwareActive }
    @Published var host = ""
    @Published var port = "6234"
    @Published var uuid = ""
    @Published var localAddress = ""
    @Published var interfaces = NetworkInterface.available()
    @Published var netConnected = false
    @Published var netBusy = false
    @Published var netUncertain = false
    @Published var mouseButtons: Int32 = 0
    @Published var heldKeys: [UInt8] = []
    @Published var latency: Double?
    @Published var netStatistics = NetTransactionStatistics()
    @Published var netMessage = "输入盒子屏幕上的连接信息"
    @Published var netError = ""
    let net = NetClient()
    @Published var peripheral: NetPeripheralInfo?
    @Published var peripheralReadAt: Date?
    @Published var peripheralMessage = "未连接，尚未读取。"
    @Published var diagnosticsMessage = "先连接设备，再读取外设信息。"
    @Published var monitorListening = false
    @Published var monitorNeedsStop = false
    @Published var monitorFrame: NetMonitorFrame?
    @Published var monitorAccepted: UInt64 = 0
    @Published var monitorRejected: UInt64 = 0
    @Published var monitorRejectedLength: Int?
    @Published var monitorCapture = NetMonitorCapture()
    @Published var monitorExportMessage = ""
    @Published var deviceTrace: [CGPoint] = [.zero]
    @Published var sentTrace: [CGPoint] = [.zero]
    private var monitorTask: Task<Void, Never>?
    private var netTask: Task<Void, Never>?
    private var shuttingDown = false
    let capture = CaptureModel()
    @Published var adaptation: NetAdaptation?
    @Published var pingRunning = false
    @Published var pingMessage = "ICMP Ping 尚未运行。"
    private var pingTask: Task<Void, Never>?


    @Published var serialPath = ""
    @Published var serialBaud = 115200
    @Published var serialPorts = SerialDevices.available()
    @Published var boardConnected = false
    @Published var boardBusy = false
    @Published var boardRunning = false
    @Published var boardMessage = "板载文件与终端需要连接 B 串口"
    @Published var boardDirectory = "/data/Script"
    @Published var boardEntries: [BoardEntry] = []
    @Published var remoteDestination = "/data/Script/demo.py"
    @Published var boardError = ""
    let repl = SerialREPL()
    private var boardTask: Task<Void, Never>?
    private var boardStopping = false
    private var pollTask: Task<Void, Never>?
    private var pollGeneration = UUID()
    private var outputPrefix = ""
    private var runOutput = Data(), runError = Data()
    @Published var console = ""
    @Published var commandLine = ""
    @Published var commandHistory: [String] = []

    @Published var documents: [EditorDocument] = []
    @Published var selectedDocument: UUID?
    @Published var workspace: URL?
    @Published var workspaceDirectory: URL?
    @Published var localEntries: [LocalEntry] = []
    @Published var fontSize: Double = 14
    @Published var logs: [LogEntry] = []
    @Published var notice: String?
    private var saveTask: Task<Void, Never>?
    private let defaults = UserDefaults.standard
    private let persist: Bool
    private var canSaveSession = true

    var activeDocument: EditorDocument? { documents.first { $0.id == selectedDocument } }
    var canUseBoard: Bool { boardConnected && !boardBusy && !boardRunning }
    var canControl: Bool { netConnected && !netBusy && !netUncertain }

    init(temporarySession: Bool = false) {
        let args = CommandLine.arguments
        persist = !temporarySession && !args.contains("--temporary-session")
        if persist {
            deviceModel = DeviceModel(rawValue: defaults.string(forKey: "device.model") ?? "") ?? .nb
            host = defaults.string(forKey: "nb.host") ?? ""
            port = defaults.string(forKey: "nb.port") ?? "6234"
            uuid = defaults.string(forKey: "nb.uuid") ?? ""
            localAddress = defaults.string(forKey: "nb.localAddress") ?? ""
            fontSize = defaults.object(forKey: "editor.fontSize") as? Double ?? 14
            serialBaud = defaults.object(forKey: "serial.baud") as? Int ?? 115200
            if FileManager.default.fileExists(atPath: sessionURL.path) {
                do {
                    let saved = try JSONDecoder().decode(SavedSession.self, from: Data(contentsOf: sessionURL))
                    documents = saved.documents; selectedDocument = saved.selected
                    workspace = saved.workspace; workspaceDirectory = workspace
                    if let directory = workspace {
                        do { localEntries = try LocalEntry.list(directory) }
                        catch { notice = "工作区暂时无法读取：\(error.localizedDescription)\n编辑草稿已恢复，可重新选择工作区。" }
                    }
                } catch {
                    let originalError = error.localizedDescription
                    let backup = sessionURL.appendingPathExtension("recovery-" + UUID().uuidString)
                    do {
                        try FileManager.default.copyItem(at: sessionURL, to: backup)
                        notice = "会话恢复不完整：\(originalError)\n原始草稿已保留：\(backup.path)"
                    } catch {
                        canSaveSession = false
                        notice = "会话读取失败：\(originalError)\n自动草稿保存已暂停，避免覆盖原始文件。可另存当前脚本。"
                    }
                }
            }
        }
        func argument(_ name: String) -> String? {
            if let inline = args.first(where: { $0.hasPrefix(name + "=") }) { return String(inline.dropFirst(name.count + 1)) }
            guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }
            return args[index + 1]
        }
        if let value = argument("--host") { host = value }
        if let value = argument("--port") { port = value }
        if let value = argument("--uuid") { uuid = value }
        if let value = argument("--local") { localAddress = value }
        if let value = argument("--serial") { serialPath = value }
        if documents.isEmpty { newDocument(name: "hello_nb.py", text: Self.exampleInfo) }
        if activeDocument == nil { selectedDocument = documents.first?.id }
        if let document = activeDocument { remoteDestination = document.remotePath ?? SerialREPL.join(boardDirectory, document.name) }
        if serialPath.isEmpty { serialPath = serialPorts.first ?? "" }
        page = ["diagnostics": Page.diagnostics, "capture": .capture][argument("--page")] ?? .control
        log("KMBox Mac 已就绪。连接只会在点击连接后建立。")
    }

    func log(_ text: String, error: Bool = false) {
        logs.append(LogEntry(text: text, error: error))
        if logs.count > 500 { logs.removeFirst(logs.count - 500) }
    }

    func refreshInterfaces() { interfaces = NetworkInterface.available(); serialPorts = SerialDevices.available() }

    func connectNet() {
        guard !netBusy, !firmwareActive else { return }
        guard deviceModel.supportsNet else { notice = deviceModel.compatibility; return }
        netAction("连接 " + deviceModel.rawValue) { [self] in
            let configuration = try NetConfiguration(host: host, port: port, uuid: uuid, localAddress: localAddress)
            let result = try await net.connect(configuration)
            peripheral = nil; peripheralReadAt = nil
            adaptation = nil
            diagnosticsMessage = "握手成功，正在读取可查询的外设信息…"
            clearTraces()
            if persist { defaults.set(host, forKey: "nb.host"); defaults.set(port, forKey: "nb.port"); defaults.set(uuid, forKey: "nb.uuid"); defaults.set(localAddress, forKey: "nb.localAddress") }
            do {
                let read = try await readPeripheralSnapshot()
                return [result, read]
            } catch {
                // Optional configuration discovery must not turn a valid control handshake into a failure.
                log("连接后的外设查询：" + error.localizedDescription, error: true)
                diagnosticsMessage = "控制连接已建立；外设信息读取失败，详见读取状态。"
                return [result]
            }
        }
    }

    func disconnectNet() { netAction("断开连接") { [self] in
        stopPing(); capture.monitorStopped(); adaptation = nil
        monitorTask?.cancel(); monitorTask = nil
        defer { peripheral = nil; peripheralReadAt = nil; diagnosticsMessage = "已断开；重新连接后读取。" }
        try await net.disconnect(); return []
    } }

    func netAction(_ name: String, _ action: @escaping @MainActor () async throws -> [NetReceipt]) {
        guard !netBusy, !shuttingDown else { return }
        netBusy = true; netError = ""
        netTask = Task {
            do {
                let receipts = try await action()
                if let last = receipts.last { latency = last.milliseconds }
                for receipt in receipts {
                    log(String(format: "%@ · 序号 %u · %d 字节 · %.2f ms · 忽略 %d 个不匹配应答", name, receipt.sequence,
                               receipt.bytesSent, receipt.milliseconds, receipt.ignoredResponses))
                }
                if receipts.isEmpty { log(name) }
                netMessage = name + "完成"
            } catch { netError = error.localizedDescription; netMessage = "操作未完成"; log(name + "：" + error.localizedDescription, error: true) }
            await syncNetStatus()
            netBusy = false
        }
    }

    func releaseAll() {
        guard !shuttingDown else { return }
        // An explicit recovery action can queue behind an in-flight bounded transaction.
        Task {
            do {
                let receipts = try await net.releaseAll()
                netError = ""; netMessage = "释放应答已确认"
                log("全部释放：已收到 \(receipts.count) 个应答")
            } catch { netError = error.localizedDescription; log(netError, error: true) }
            await syncNetStatus()
        }
    }

    private func syncNetStatus() async {
        let status = await net.status()
        netStatistics = await net.statistics()
        netConnected = status.connected; netUncertain = status.uncertain
        monitorListening = status.monitorPort != nil; monitorNeedsStop = status.monitorNeedsStop
        if !status.connected {
            peripheral = nil; peripheralReadAt = nil; adaptation = nil
            peripheralMessage = "未连接，尚未读取。"
        }
        if !monitorListening { monitorTask?.cancel(); monitorTask = nil; capture.monitorStopped() }
        mouseButtons = status.mouse.buttons; heldKeys = status.keyboard.keys
        heldKeys += (0..<8).compactMap { status.keyboard.modifiers & (1 << $0) != 0 ? UInt8(0xe0 + $0) : nil }
    }

    func move(_ x: Int32, _ y: Int32) { netAction("移动 \(x), \(y)") { [self] in
        let result = try await net.move(x: x, y: y)
        appendTrace(&sentTrace, x: Double(x), y: Double(y)); return [result]
    } }
    func timedMove(_ x: Int32, _ y: Int32, milliseconds: Int, controls: NetBezierControls? = nil) {
        netAction(controls == nil ? "自动移动" : "Bézier 移动") { [self] in
            let movement = try NetTimedMovement(x: x, y: y, milliseconds: milliseconds)
            let receipt: NetReceipt
            if let controls { receipt = try await net.moveBezier(movement, controls: controls) }
            else { receipt = try await net.moveAutomatically(movement) }
            // Only the requested endpoint is known; never manufacture intermediate device output.
            appendTrace(&sentTrace, x: Double(x), y: Double(y)); return [receipt]
        }
    }
    func clearNetStatistics() {
        Task { await net.clearStatistics(); netStatistics = await net.statistics() }
    }
    func exportMonitor() {
        let panel = NSSavePanel()
        panel.title = "导出原始监控记录"; panel.nameFieldStringValue = "kmbox-monitor.jsonl"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try monitorCapture.jsonLines().write(to: url, options: .atomic)
            monitorExportMessage = "已导出 \(monitorCapture.records.count) 条原始记录到 \(url.path)；缓冲区已淘汰 \(monitorCapture.discardedRecords) 条。"
        } catch { notice = "导出失败：" + error.localizedDescription }
    }
    func click(_ button: Int32) { netAction("鼠标单击") { [self] in try await net.click(button) } }
    func holdMouse(_ button: Int32, down: Bool) { netAction(down ? "鼠标按下" : "鼠标释放") { [self] in [try await net.setMouseButton(button, down: down)] } }
    func scroll(_ value: Int32) { netAction("滚动 \(value)") { [self] in [try await net.scroll(value)] } }
    func tapKey(_ key: UInt8, modifiers: [UInt8]) { netAction("发送键盘按键") { [self] in try await net.tapKey(key, modifiers: modifiers) } }
    func holdKey(_ key: UInt8, down: Bool) { netAction(down ? "键盘按下" : "键盘释放") { [self] in [try await net.setKey(key, down: down)] } }

    func readPeripheral() {
        netAction("读取外设信息") { [self] in
            [try await readPeripheralSnapshot()]
        }
    }

    private func readPeripheralSnapshot() async throws -> NetReceipt {
        peripheral = nil; peripheralReadAt = nil; adaptation = nil
        peripheralMessage = "正在读取外设信息…"
        do {
            let (info, receipt) = try await net.peripheralInfo()
            peripheral = info; peripheralReadAt = Date()
            peripheralMessage = info.isEmpty ? "设备返回全零标识；可能未接外设或固件未实现查询，无法确认解析参数。" : "外设信息已从设备读取。此标识不等同于 OTG 对外枚举标识。"
            diagnosticsMessage = peripheralMessage
            return receipt
        } catch {
            peripheralMessage = "读取失败：" + error.localizedDescription
            diagnosticsMessage = peripheralMessage
            throw error
        }
    }

    func configure(_ name: String, resultMessage: String, _ action: @escaping @MainActor () async throws -> [NetReceipt]) {
        netAction(name) { [self] in
            diagnosticsMessage = "正在" + name + "…"
            do {
                let receipts = try await action()
                diagnosticsMessage = resultMessage
                return receipts
            } catch { diagnosticsMessage = error.localizedDescription; throw error }
        }
    }

    func writeParsing(mouse: Int, keyboard: Int) {
        configure("写入解析参数", resultMessage: "解析参数已写入并回读确认；键鼠实际功能仍需测试。") { [self] in
            let modes = try NetParsingModes(mouse: mouse, keyboard: keyboard)
            adaptation = nil
            peripheral = nil; peripheralReadAt = nil
            let (info, receipts) = try await net.setParsing(modes)
            peripheral = info; peripheralReadAt = Date()
            peripheralMessage = "解析参数已写入并从设备回读。"; return receipts
        }
    }

    func queryAdaptation() {
        configure("查询厂商适配", resultMessage: "已取得厂商建议，尚未写入盒子。") { [self] in
            adaptation = nil
            let (info, receipt) = try await net.peripheralInfo()
            peripheral = info; peripheralReadAt = Date()
            peripheralMessage = info.isEmpty ? "设备返回全零标识，无法查询适配建议。" : "外设信息已从设备读取。"
            adaptation = try await NetAdaptationService.query(info)
            return [receipt]
        }
    }
    func applyAdaptation() {
        guard let recommendation = adaptation else { return }
        configure("应用厂商解析建议", resultMessage: "厂商建议已写入并回读确认；请测试外设是否正常。") { [self] in
            peripheral = nil; peripheralReadAt = nil
            let (info, receipts) = try await net.setParsing(recommendation.modes, expectedPeripheral: recommendation.peripheral)
            peripheral = info; peripheralReadAt = Date()
            peripheralMessage = "解析参数已写入并从设备回读。"; return receipts
        }
    }
    func submitAdaptation(worked: Bool) {
        guard let info = peripheral, !info.isEmpty else { return }
        netAction("向厂商提交外设测试结果") { [self] in
            let modes = try NetParsingModes(mouse: Int(info.mouseMode), keyboard: Int(info.keyboardMode))
            let matching = adaptation.flatMap { $0.peripheral.raw.prefix(8) == info.raw.prefix(8) && $0.modes == modes ? $0 : nil }
            let count = worked ? matching?.successes : matching?.failures
            let code = try await NetAdaptationService.submit(info: info, modes: modes, worked: worked, previousCount: count ?? 0)
            diagnosticsMessage = "厂商反馈接口已应答，返回码 \(code)；数据库写入状态没有独立验证。"
            return []
        }
    }
    func readChipID() {
        netAction("读取芯片 ID") { [self] in
            let value = try await NetHostDiagnostics.chipID(host: host, localAddress: localAddress)
            diagnosticsMessage = "芯片 ID：\(value.text)（独立 UDP 1752 查询）"; return []
        }
    }
    func startPing() {
        guard !pingRunning, !shuttingDown else { return }
        let target = host, source = localAddress
        pingRunning = true
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    let result = try await NetHostDiagnostics.ping(host: target, localAddress: source)
                    guard !Task.isCancelled else { return }
                    self?.pingMessage = "ICMP \(target)：" + (result.reached ? result.milliseconds.map { String(format: "%.2f ms", $0) } ?? "有应答" : "无应答")
                    try await Task.sleep(nanoseconds: 2_500_000_000)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.pingMessage = error.localizedDescription; self?.pingRunning = false; return
                }
            }
        }
    }
    func stopPing() { pingTask?.cancel(); pingTask = nil; pingRunning = false }

    func beginMonitor(port: String) {
        netAction("启动监控") { [self] in
            guard let port = UInt16(port) else { throw KMError.invalid("监控端口需要整数。") }
            do {
                let receipt = try await net.startMonitor(port: port)
                startMonitorPolling(); return [receipt]
            } catch {
                let status = await net.status()
                if status.monitorPort != nil { startMonitorPolling() }
                throw error
            }
        }
    }
    func endMonitor() {
        netAction("停止监控") { [self] in
            monitorTask?.cancel(); monitorTask = nil
            return [try await net.stopMonitor()]
        }
    }
    private func startMonitorPolling() {
        monitorCapture = NetMonitorCapture(); monitorExportMessage = ""
        monitorFrame = nil; monitorAccepted = 0; monitorRejected = 0; monitorRejectedLength = nil
        deviceTrace = [.zero]
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 33_000_000) } catch { break }
                guard let self else { break }
                do {
                    let batch = try await self.net.readMonitor()
                    guard !Task.isCancelled else { break }
                    self.monitorAccepted = batch.accepted; self.monitorRejected = batch.rejected
                    self.monitorRejectedLength = batch.lastRejectedLength
                    self.monitorCapture.append(batch.records)
                    for frame in batch.frames {
                        self.monitorFrame = frame
                        self.capture.receiveMouse(frame)
                        if frame.x != 0 || frame.y != 0 { self.appendTrace(&self.deviceTrace, x: Double(frame.x), y: Double(frame.y)) }
                    }
                } catch {
                    guard !Task.isCancelled else { break }
                    self.netError = error.localizedDescription
                    self.log("监控接收：" + error.localizedDescription, error: true)
                    break
                }
            }
        }
    }
    func clearTraces() { deviceTrace = [.zero]; sentTrace = [.zero] }
    private func appendTrace(_ points: inout [CGPoint], x: Double, y: Double) {
        let previous = points.last ?? .zero
        points.append(CGPoint(x: previous.x + x, y: previous.y + y))
        if points.count > 600 { points.removeFirst(points.count - 600) }
    }

    func connectBoard() {
        guard !firmwareActive else { return }
        guard deviceModel.supportsSerialREPL else { notice = deviceModel.compatibility; return }
        boardAction("连接串口") { [self] in
            boardMessage = try await repl.connect(path: serialPath, baud: serialBaud)
            console += boardMessage + "\n"
            boardDirectory = await repl.workingDirectory
            boardEntries = try await repl.list(boardDirectory)
            remoteDestination = activeDocument?.remotePath ?? SerialREPL.join(boardDirectory, activeDocument?.name ?? "demo.py")
        }
    }

    func disconnectBoard() {
        boardAction("断开串口") { [self] in
            try await repl.disconnect(); boardEntries = []; boardMessage = "串口已断开"
        }
    }

    func boardAction(_ name: String, _ action: @escaping @MainActor () async throws -> Void) {
        guard !boardBusy && !boardRunning else { return }
        boardBusy = true; boardError = ""
        boardTask = Task {
            do { try await action(); if !Task.isCancelled { log(name + "完成") } }
            catch is CancellationError { }
            catch { boardError = error.localizedDescription; log(name + "：" + boardError, error: true) }
            let connected = await repl.isConnected()
            let running = await repl.running
            guard !boardStopping else { return }
            boardConnected = connected; boardRunning = running
            boardBusy = false
            if boardRunning { beginPolling() }
        }
    }

    func refreshBoard() {
        boardAction("读取目录") { [self] in boardEntries = try await repl.list(boardDirectory) }
    }
    func enterBoardDirectory(_ directory: String) {
        boardAction("读取目录") { [self] in
            let entries = try await repl.list(directory)
            boardDirectory = directory; boardEntries = entries
        }
    }
    func openBoardEntry(_ entry: BoardEntry, reload: Bool = false) {
        if entry.isDirectory { enterBoardDirectory(entry.path); return }
        let existing = documents.first(where: { $0.remotePath == entry.path })
        if let existing {
            selectedDocument = existing.id; remoteDestination = entry.path
            if !reload { return }
            if existing.dirty {
                let alert = NSAlert(); alert.messageText = "从设备重新读取“\(entry.name)”？"
                alert.informativeText = "这会替换当前编辑区里尚未保存的修改。"
                alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "重新读取")
                guard alert.runModal() == .alertSecondButtonReturn else { return }
            }
        }
        boardAction("读取 \(entry.name)") { [self] in
            let data = try await repl.readFile(entry.path)
            try Task.checkCancellation()
            if let existing {
                guard let index = documents.firstIndex(where: { $0.id == existing.id && $0.remotePath == entry.path }) else { return }
                try documents[index].reloadFromDevice(data, replacingText: existing.text)
                scheduleSave(); return
            }
            let text = try EditorDocument.decodeSource(data, name: entry.name)
            var document = EditorDocument(name: entry.name, text: text)
            document.remotePath = entry.path; document.remoteBaseline = data
            documents.append(document); selectedDocument = document.id; remoteDestination = entry.path
            scheduleSave()
        }
    }

    func upload(runAfter: Bool = false) {
        guard let document = activeDocument else { return }
        let path = remoteDestination
        let expected = document.remotePath == path ? document.remoteBaseline : nil
        boardAction(runAfter ? "上传并运行" : "上传脚本") { [self] in
            let data = Data(document.text.utf8)
            let result = try await repl.upload(data, to: path, expected: expected)
            if let index = documents.firstIndex(where: { $0.id == document.id }) {
                documents[index].remotePath = path; documents[index].remoteBaseline = data
                if documents[index].localURL == nil { documents[index].savedText = document.text }
            }
            boardMessage = "\(result.bytes) 字节上传完成，读回一致"
            if let backup = result.backupPath { log("保留设备原文件：" + backup) }
            boardEntries = try await repl.list(boardDirectory)
            scheduleSave()
            if runAfter {
                prepareOutput("运行设备文件：\(path)")
                try await repl.beginFile(path)
            }
        }
    }

    func runEditor() {
        guard let document = activeDocument else { return }
        boardAction("运行编辑区") { [self] in
            prepareOutput("运行编辑区：\(document.name)（不写入设备文件）")
            try await repl.begin(document.text)
        }
    }

    func runFile(_ entry: BoardEntry) {
        boardAction("运行 \(entry.name)") { [self] in
            prepareOutput("运行设备文件：\(entry.path)")
            try await repl.beginFile(entry.path)
        }
    }

    func executeCommand() {
        let command = commandLine
        if boardRunning {
            commandLine = ""
            Task {
                do { try await repl.sendInput(command); log("已向运行中的脚本发送一行输入") }
                catch { boardError = error.localizedDescription; log(boardError, error: true) }
            }
            return
        }
        guard !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        commandLine = ""; commandHistory.append(command)
        if commandHistory.count > 100 { commandHistory.removeFirst() }
        boardAction("终端执行") { [self] in prepareOutput(">>> " + command); try await repl.beginInteractive(command) }
    }

    func clearConsole() { console = ""; outputPrefix = ""; runOutput.removeAll(); runError.removeAll() }

    private func prepareOutput(_ title: String) {
        outputPrefix = String(console.suffix(200_000)) + "\n" + title + "\n"
        runOutput = Data(); runError = Data(); console = outputPrefix
    }
    private func displayChunk(_ chunk: REPLChunk) {
        runOutput.append(chunk.output); runError.append(chunk.error)
        if runOutput.count > 1_000_000 { runOutput = Data(runOutput.suffix(800_000)); outputPrefix = "[较早的输出已截断]\n" }
        if runError.count > 100_000 { runError = Data(runError.suffix(80_000)) }
        console = outputPrefix + String(decoding: runOutput, as: UTF8.self) + String(decoding: runError, as: UTF8.self)
    }
    private func beginPolling() {
        pollTask?.cancel()
        let generation = UUID(); pollGeneration = generation
        pollTask = Task {
            do {
                while !Task.isCancelled {
                    let chunk = try await repl.pollOutput()
                    guard pollGeneration == generation else { return }
                    displayChunk(chunk)
                    if chunk.completed { boardRunning = false; log("脚本已结束" + (runError.isEmpty ? "" : "，有错误输出"), error: !runError.isEmpty); return }
                    try await Task.sleep(nanoseconds: 40_000_000)
                }
            } catch is CancellationError { return }
            catch {
                guard pollGeneration == generation else { return }
                boardError = error.localizedDescription; boardRunning = await repl.running
                boardConnected = await repl.isConnected(); log(boardError, error: true)
            }
        }
    }

    func stopBoard() {
        guard !boardStopping else { return }
        boardStopping = true; boardBusy = true
        let previous = boardTask
        boardTask?.cancel(); pollTask?.cancel(); pollGeneration = UUID()
        boardTask = Task {
            await previous?.value
            do { displayChunk(try await repl.stop()); log("已发送 Ctrl-C 并确认脚本结束") }
            catch { boardError = error.localizedDescription; log(boardError, error: true) }
            boardRunning = await repl.running; boardConnected = await repl.isConnected(); boardBusy = false
            boardStopping = false
        }
    }

    func checkSyntax() {
        guard let document = activeDocument else { return }
        if canUseBoard {
            boardAction("MicroPython 语法检查") { [self] in
                let result = try await repl.syntaxCheck(document.text, filename: document.name)
                console += "\n" + result; boardMessage = result.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            Task {
                do {
                    let result = try await Task.detached { try LocalPython.check(document.text) }.value
                    console += "\n" + result; log(result)
                } catch { console += "\n" + error.localizedDescription; log(error.localizedDescription, error: true) }
            }
        }
    }

    func newDocument(name: String = "untitled.py", text: String = "") {
        let document = EditorDocument(name: name, text: text)
        documents.append(document); selectedDocument = document.id; page = .editor; scheduleSave()
        remoteDestination = SerialREPL.join(boardDirectory, name)
    }
    func updateText(_ value: String) {
        guard let index = documents.firstIndex(where: { $0.id == selectedDocument }) else { return }
        documents[index].text = value; scheduleSave()
    }
    func selectDocument(_ id: UUID) {
        selectedDocument = id
        if let document = activeDocument { remoteDestination = document.remotePath ?? SerialREPL.join(boardDirectory, document.name) }
        scheduleSave()
    }
    func closeDocument(_ id: UUID) {
        guard let document = documents.first(where: { $0.id == id }) else { return }
        if document.dirty {
            let alert = NSAlert(); alert.messageText = "关闭“\(document.name)”？"; alert.informativeText = "此标签页包含尚未保存的修改。"
            alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "放弃修改并关闭")
            guard alert.runModal() == .alertSecondButtonReturn else { return }
        }
        documents.removeAll { $0.id == id }
        if selectedDocument == id {
            if let next = documents.last { selectDocument(next.id) }
            else { selectedDocument = nil; remoteDestination = "" }
        }
        scheduleSave()
    }
    func chooseFile() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = true; panel.canChooseDirectories = false
        if panel.runModal() == .OK { panel.urls.forEach { openLocal($0) } }
    }
    func openLocal(_ url: URL) {
        if let document = documents.first(where: { $0.localURL == url }) { selectDocument(document.id); page = .editor; return }
        do {
            let document: EditorDocument
            do { document = try EditorDocument.open(url) }
            catch is DocumentDecodingError {
                let alert = NSAlert(); alert.messageText = "选择“\(url.lastPathComponent)”的文本编码"
                alert.informativeText = "此文件不是 UTF-8。按所选编码读取，后续保存与上传使用 UTF-8；Python 文件开头的编码声明会同步调整。"
                alert.addButton(withTitle: "取消")
                alert.addButton(withTitle: "使用 GB18030 / GBK")
                alert.addButton(withTitle: "使用 UTF-16（带 BOM）")
                switch alert.runModal() {
                case .alertSecondButtonReturn: document = try EditorDocument.open(url, encoding: .gb18030)
                case .alertThirdButtonReturn: document = try EditorDocument.open(url, encoding: .utf16)
                default: return
                }
            }
            documents.append(document); selectDocument(document.id); page = .editor
        } catch { notice = error.localizedDescription }
    }
    func saveLocal(asNew: Bool = false) {
        guard var document = activeDocument, let index = documents.firstIndex(where: { $0.id == document.id }) else { return }
        let followsLocalName = document.remotePath == nil && remoteDestination == SerialREPL.join(boardDirectory, document.name)
        var target = asNew ? nil : document.localURL
        var baseline = asNew ? nil : document.localBaseline
        if target == nil {
            let panel = NSSavePanel(); panel.nameFieldStringValue = document.name
            panel.directoryURL = workspaceDirectory; panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            target = url
            // NSSavePanel owns the user's Replace confirmation for an existing destination.
            do { baseline = FileManager.default.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil }
            catch { notice = error.localizedDescription; return }
        }
        do {
            try document.save(to: target!, replacing: baseline)
            if followsLocalName { remoteDestination = SerialREPL.join(boardDirectory, document.name) }
            documents[index] = document; scheduleSave(); refreshLocal(); log("已保存：" + target!.path)
        } catch { notice = error.localizedDescription }
    }
    func chooseWorkspace() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true
        panel.prompt = "选择工作区"
        if panel.runModal() == .OK, let url = panel.url { workspace = url; workspaceDirectory = url; refreshLocal(); scheduleSave() }
    }
    func refreshLocal() {
        guard let directory = workspaceDirectory else { localEntries = []; return }
        do { localEntries = try LocalEntry.list(directory) } catch { notice = error.localizedDescription }
    }
    func openLocalEntry(_ entry: LocalEntry) {
        if entry.isDirectory { workspaceDirectory = entry.url; refreshLocal() } else { openLocal(entry.url) }
    }

    func namedOperation(title: String, initial: String = "", action: (String) -> Void) {
        let alert = NSAlert(); alert.messageText = title
        let input = NSTextField(string: initial); input.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        alert.accessoryView = input; alert.addButton(withTitle: "确定"); alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = input
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let value = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\0") else { notice = "请输入有效名称。"; return }
        action(value)
    }

    func createBoardDirectory() {
        namedOperation(title: "新建板载文件夹") { name in
            boardAction("新建文件夹") { [self] in
                try await repl.createDirectory(SerialREPL.join(boardDirectory, name)); boardEntries = try await repl.list(boardDirectory)
            }
        }
    }
    func renameBoard(_ entry: BoardEntry) {
        namedOperation(title: "重命名 \(entry.name)", initial: entry.name) { name in
            boardAction("重命名") { [self] in
                let destination = SerialREPL.join(boardDirectory, name)
                try await repl.rename(entry.path, to: destination)
                for index in documents.indices {
                    guard let old = documents[index].remotePath else { continue }
                    if old == entry.path || (entry.isDirectory && old.hasPrefix(entry.path + "/")) {
                        let updated = destination + old.dropFirst(entry.path.count)
                        documents[index].remotePath = updated
                        if documents[index].localURL == nil { documents[index].name = (updated as NSString).lastPathComponent }
                    }
                }
                if let active = activeDocument?.remotePath { remoteDestination = active }
                boardEntries = try await repl.list(boardDirectory); scheduleSave()
            }
        }
    }
    func deleteBoard(_ entry: BoardEntry) {
        let alert = NSAlert(); alert.messageText = "删除设备上的“\(entry.name)”？"
        alert.informativeText = entry.isDirectory ? "仅删除空文件夹。" : "这会删除盒内文件，Mac 上的文件不受影响。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "删除")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        boardAction("删除设备文件") { [self] in
            try await repl.remove(entry.path, directory: entry.isDirectory)
            boardEntries = try await repl.list(boardDirectory)
        }
    }
    func downloadBoard(_ entry: BoardEntry) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = entry.name; panel.directoryURL = workspaceDirectory
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        let expected: Data?
        do { expected = FileManager.default.fileExists(atPath: destination.path) ? try Data(contentsOf: destination) : nil }
        catch { notice = error.localizedDescription; return }
        boardAction("下载设备文件") { [self] in
            let data = try await repl.readFile(entry.path)
            try LocalFiles.write(data, to: destination, replacing: expected)
            log("已下载至 " + destination.path); refreshLocal()
        }
    }
    func setStartup(_ entry: BoardEntry) {
        let alert = NSAlert(); alert.messageText = "把“\(entry.name)”设为启动脚本？"
        alert.informativeText = "将写入 main.py，保留原文件备份。NB 仍需在设备页面开启 Python/串口功能。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "设置启动脚本")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        boardAction("设置启动脚本") { [self] in
            let main = SerialREPL.join(await repl.workingDirectory, "main.py")
            let baseline = try await repl.fileExists(main) ? try await repl.readFile(main) : nil
            let result = try await repl.setStartupScript(entry.path, expectedMain: baseline)
            if let backup = result.backupPath { log("原 main.py 备份：" + backup) }
            boardEntries = try await repl.list(boardDirectory)
        }
    }

    func createLocalDirectory() {
        guard let directory = workspaceDirectory else { return }
        namedOperation(title: "新建本地文件夹") { name in
            do { try FileManager.default.createDirectory(at: directory.appendingPathComponent(name), withIntermediateDirectories: false); refreshLocal() }
            catch { notice = error.localizedDescription }
        }
    }
    func renameLocal(_ entry: LocalEntry) {
        namedOperation(title: "重命名 \(entry.name)", initial: entry.name) { name in
            let followsLocalName = activeDocument.map {
                $0.remotePath == nil && remoteDestination == SerialREPL.join(boardDirectory, $0.name)
            } ?? false
            let destination = entry.url.deletingLastPathComponent().appendingPathComponent(name)
            do {
                try FileManager.default.moveItem(at: entry.url, to: destination)
                for index in documents.indices {
                    guard let old = documents[index].localURL else { continue }
                    if old == entry.url || (entry.isDirectory && old.path.hasPrefix(entry.url.path + "/")) {
                        let updated = URL(fileURLWithPath: destination.path + old.path.dropFirst(entry.url.path.count))
                        documents[index].localURL = updated; documents[index].name = updated.lastPathComponent
                    }
                }
                if followsLocalName, let active = activeDocument { remoteDestination = SerialREPL.join(boardDirectory, active.name) }
                refreshLocal(); scheduleSave()
            } catch { notice = error.localizedDescription }
        }
    }
    func trashLocal(_ entry: LocalEntry) {
        let alert = NSAlert(); alert.messageText = "将“\(entry.name)”移到废纸篓？"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "移到废纸篓")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        do { try FileManager.default.trashItem(at: entry.url, resultingItemURL: nil); refreshLocal() }
        catch { notice = error.localizedDescription }
    }

    func chooseFirmware() {
        guard !firmwareActive else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = false
        panel.allowedContentTypes = [UTType(filenameExtension: "cpio") ?? .data]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            firmware = try NBFirmware(url: url); firmwareName = url.lastPathComponent; firmwareError = ""
            log("NB 固件格式已检查：" + firmwareName + " SHA-256 " + (firmware?.sha256 ?? ""))
        } catch { firmware = nil; firmwareName = ""; firmwareError = error.localizedDescription }
    }
    func startFirmwareServer() {
        guard deviceModel.supportsFirmwareHosting, !firmwareActive, !netConnected, !boardConnected,
              !netBusy, !boardBusy, let firmware else { return }
        do {
            _ = try firmwareServer.start(firmware: firmware, localAddress: firmwareAddress, deviceAddress: firmwareDeviceAddress)
            firmwareError = ""; firmwareStatus = firmwareServer.status()
            log("NB 固件服务启动于 " + firmwareAddress + ":80" + (firmwareDeviceAddress.isEmpty ? "" : "，仅允许来源 " + firmwareDeviceAddress))
            firmwarePoll?.cancel()
            firmwarePoll = Task {
                while !Task.isCancelled {
                    firmwareStatus = firmwareServer.status()
                    if !firmwareActive { return }
                    do { try await Task.sleep(nanoseconds: 200_000_000) } catch { return }
                }
            }
        } catch { firmwareError = error.localizedDescription; log(firmwareError, error: true) }
    }
    func stopFirmwareServer() {
        firmwarePoll?.cancel(); firmwarePoll = nil
        firmwareServer.stop(); firmwareStatus = firmwareServer.status()
    }

    func exportLogs() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "kmbox-session.log"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let text = logs.map { "\($0.date.ISO8601Format()) \($0.error ? "ERROR" : "INFO") \($0.text)" }.joined(separator: "\n")
            try Data(text.utf8).write(to: url, options: .atomic)
        } catch { notice = error.localizedDescription }
    }

    func resetPreferences() {
        guard !netConnected, !boardConnected, !netBusy, !boardBusy, !firmwareActive else { return }
        let alert = NSAlert(); alert.messageText = "初始化应用配置？"
        alert.informativeText = "将清除已保存的连接信息和工作区选择，并恢复默认字号、波特率。编辑草稿会保留。"
        alert.addButton(withTitle: "取消"); alert.addButton(withTitle: "初始化配置")
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        host = ""; port = "6234"; uuid = ""; localAddress = ""
        deviceModel = .nb; firmwareAddress = ""; firmwareDeviceAddress = ""
        latency = nil; netError = ""; netMessage = "输入盒子屏幕上的连接信息"
        fontSize = 14; serialBaud = 115200
        refreshInterfaces(); serialPath = serialPorts.first ?? ""
        workspace = nil; workspaceDirectory = nil; localEntries = []
        if persist {
            for key in ["nb.host", "nb.port", "nb.uuid", "nb.localAddress", "editor.fontSize", "serial.baud", "device.model"] { defaults.removeObject(forKey: key) }
            saveSession()
        }
        log("应用配置已初始化，编辑草稿已保留")
    }

    private var sessionURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KMBoxMac", isDirectory: true).appendingPathComponent("session.json")
    }
    func scheduleSave() {
        guard persist else { return }
        saveTask?.cancel()
        saveTask = Task {
            do { try await Task.sleep(nanoseconds: 400_000_000) } catch { return }
            saveSession()
        }
    }
    func saveSession() {
        guard persist && canSaveSession else { return }
        do {
            let data = try JSONEncoder().encode(SavedSession(documents: documents, selected: selectedDocument, workspace: workspace))
            try FileManager.default.createDirectory(at: sessionURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: sessionURL, options: .atomic)
            defaults.set(fontSize, forKey: "editor.fontSize")
            defaults.set(serialBaud, forKey: "serial.baud")
            defaults.set(deviceModel.rawValue, forKey: "device.model")
        } catch { log("草稿保存失败：" + error.localizedDescription, error: true) }
    }

    func shutdown() async -> [String] {
        shuttingDown = true
        defer { shuttingDown = false }
        stopPing()
        await capture.shutdown()
        await netTask?.value
        stopFirmwareServer()
        monitorTask?.cancel(); monitorTask = nil
        boardStopping = true; boardBusy = true; pollGeneration = UUID()
        pollTask?.cancel(); boardTask?.cancel()
        await boardTask?.value
        var failures: [String] = []
        do { try await net.disconnect() } catch { failures.append(error.localizedDescription); log(error.localizedDescription, error: true) }
        do { try await repl.disconnect() } catch { failures.append(error.localizedDescription); log(error.localizedDescription, error: true) }
        await syncNetStatus(); boardConnected = await repl.isConnected(); boardRunning = await repl.running; boardBusy = false
        boardStopping = false
        saveSession()
        return failures
    }

    static let exampleInfo = """
    # 在 KMBox NB 内运行；先连接 B 串口。
    import sys
    import os

    print("Hello, KMBox NB!")
    print(sys.implementation)
    print("Working directory:", os.getcwd())
    print("Files:", os.listdir())
    """ + "\n"
    static let exampleLoop = """
    # 点击停止可用 Ctrl-C 中断此循环。
    import time

    for i in range(100):
        print("tick", i)
        time.sleep(1)
    """ + "\n"
    static let exampleModules = """
    # 仅检查可用模块，不启动网络服务或改写文件。
    help('modules')
    import os
    print("dupterm available:", hasattr(os, 'dupterm'))
    """ + "\n"
}
