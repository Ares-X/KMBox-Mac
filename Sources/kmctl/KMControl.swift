import Foundation
import KMBoxCore
import Darwin

@main
struct KMControl {
    static func main() async {
        var args = Array(CommandLine.arguments.dropFirst())
        if args.isEmpty || args.contains("--help") { print(help); return }
        do {
            func option(_ name: String, default fallback: String = "") throws -> String {
                guard let index = args.firstIndex(of: name) else { return fallback }
                guard index + 1 < args.count else { throw KMError.invalid("选项 \(name) 缺少值。") }
                let value = args[index + 1]; args.removeSubrange(index...index + 1); return value
            }
            let host = try option("--host"), port = try option("--port"), uuid = try option("--uuid")
            let local = try option("--local"), serialPath = try option("--serial")
            let monitorOutputPath = try option("--monitor-output")
            let showStats = args.contains("--stats"); args.removeAll { $0 == "--stats" }
            let httpPort = try option("--http-port", default: "80")
            guard let timeout = Double(try option("--timeout", default: "1")) else { throw KMError.invalid("--timeout 需要有效的秒数。") }
            guard let baud = Int(try option("--baud", default: "115200")), SerialREPL.supportedBaudRates.contains(baud) else { throw KMError.invalid("不支持的 --baud 波特率。") }
            let replace = args.contains("--replace"); args.removeAll { $0 == "--replace" }
            let command = args.first ?? ""
            guard monitorOutputPath.isEmpty || (command == "monitor" && serialPath.isEmpty) else {
                throw KMError.invalid("--monitor-output 仅用于 Net monitor。")
            }
            guard !showStats || (serialPath.isEmpty && !["ping", "chip-id", "interfaces", "ports", "firmware-check", "firmware-serve"].contains(command)) else {
                throw KMError.invalid("--stats 仅用于建立 Net 会话的命令。")
            }
            guard !replace || ["put", "get"].contains(command) else { throw KMError.invalid("--replace 仅适用于 put / get。") }
            if ["interfaces", "ports"].contains(command), args.count != 1 { throw KMError.invalid("\(command) 不接受额外参数。") }
            if command == "interfaces" {
                for item in NetworkInterface.available() { print("\(item.name)\t\(item.address)") }
                return
            }
            if command == "firmware-serve" {
                guard args.count == 2, let listenPort = UInt16(httpPort), listenPort > 0 else {
                    throw KMError.invalid("用法：--local Mac网卡IPv4 [--host NB的IPv4] [--http-port 80] firmware-serve NB固件.cpio")
                }
                let image = try NBFirmware(url: URL(fileURLWithPath: args[1]))
                let server = FirmwareServer(); defer { server.stop() }
                let stopped = InterruptFlag()
                signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
                let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                    let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                    source.setEventHandler { stopped.set() }; source.resume(); return source
                }
                defer { signals.forEach { $0.cancel() }; signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL) }
                let boundPort = try server.start(firmware: image, localAddress: local, deviceAddress: host, port: listenPort)
                FileHandle.standardOutput.write(Data("Serving http://\(local):\(boundPort)/kmboxNB.cpio\(host.isEmpty ? "" : " for " + host + " only")\n".utf8))
                var previous = ""
                while !stopped.isSet {
                    let status = server.status()
                    if status.message != previous {
                        previous = status.message
                        FileHandle.standardOutput.write(Data((previous + "\n").utf8))
                    }
                    guard status.active else { throw KMError.io(status.message) }
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
                return
            }
            if command == "firmware-check" {
                guard args.count == 2 else { throw KMError.invalid("用法：firmware-check NB固件.cpio") }
                let image = try NBFirmware(url: URL(fileURLWithPath: args[1]))
                print("NB CPIO 格式检查通过；不是设备刷写验收或数字签名验证。")
                print("Bytes: \(image.data.count)\nSHA-256: \(image.sha256)")
                image.warnings.forEach { print("注意：" + $0) }
                return
            }
            if command == "ports" { SerialDevices.available().forEach { print($0) }; return }
            if command == "ping" || command == "chip-id" {
                guard args.count == 1, serialPath.isEmpty else { throw KMError.invalid("\(command) 不接受额外参数或串口。") }
                if command == "ping" { try printJSON(await NetHostDiagnostics.ping(host: host, localAddress: local)) }
                else { try printJSON(await NetHostDiagnostics.chipID(host: host, localAddress: local, timeout: timeout)) }
                return
            }
            if !serialPath.isEmpty {
                let repl = SerialREPL()
                // Prepare one operation before opening the port; preparation performs no device I/O.
                let operation: @Sendable () async throws -> Void
                switch command {
                case "ls":
                    guard args.count <= 2 else { throw KMError.invalid("用法：ls [远端目录]") }
                    let directory = args.count == 2 ? args[1] : nil
                    operation = {
                        let workingDirectory = await repl.workingDirectory
                        let target = directory ?? workingDirectory
                        for file in try await repl.list(target) { print("\(file.isDirectory ? "d" : "f")\t\(file.size)\t\(file.path)") }
                    }
                case "cat":
                    guard args.count == 2 else { throw KMError.invalid("用法：cat 远端路径") }
                    let path = args[1]
                    operation = { FileHandle.standardOutput.write(try await repl.readFile(path)) }
                case "put":
                    guard args.count == 3 else { throw KMError.invalid("用法：put 本地文件 远端路径 [--replace]") }
                    let data = try Data(contentsOf: URL(fileURLWithPath: args[1])), path = args[2]
                    guard data.count <= SerialREPL.maximumFileBytes else { throw KMError.invalid("文件不得超过 1 MiB。") }
                    operation = {
                        let exists = replace ? try await repl.fileExists(path) : false
                        let baseline = exists ? try await repl.readFile(path) : nil
                        let result = try await repl.upload(data, to: path, expected: baseline)
                        print("上传并校验 \(result.bytes) 字节")
                        if let backup = result.backupPath { print("原文件备份：" + backup) }
                    }
                case "get":
                    guard args.count == 3 else { throw KMError.invalid("用法：get 远端文件 本地路径 [--replace]") }
                    let path = args[1], url = URL(fileURLWithPath: args[2])
                    let exists = FileManager.default.fileExists(atPath: url.path)
                    if exists && !replace { throw KMError.conflict("目标文件已存在，需要 --replace 才能替换。") }
                    let baseline = exists ? try Data(contentsOf: url) : nil
                    operation = { try LocalFiles.write(try await repl.readFile(path), to: url, replacing: baseline) }
                case "mkdir", "rm", "rmdir":
                    guard args.count == 2 else { throw KMError.invalid("\(command) 需要一个远端路径。") }
                    let path = args[1], action = command
                    operation = {
                        if action == "mkdir" { try await repl.createDirectory(path) }
                        else { try await repl.remove(path, directory: action == "rmdir") }
                    }
                case "mv":
                    guard args.count == 3 else { throw KMError.invalid("用法：mv 原远端路径 新远端路径") }
                    let old = args[1], new = args[2]
                    operation = { try await repl.rename(old, to: new) }
                case "exec", "run":
                    guard args.count == 2 else { throw KMError.invalid("exec 需要代码字符串；run 需要本地脚本路径。") }
                    let code = command == "run" ? try EditorDocument.open(URL(fileURLWithPath: args[1])).text : args[1]
                    _ = try SerialREPL.sourceData(code)
                    operation = {
                        try await repl.begin(code)
                        var failed = false
                        while true {
                            try Task.checkCancellation()
                            let chunk = try await repl.pollOutput()
                            FileHandle.standardOutput.write(chunk.output)
                            FileHandle.standardError.write(chunk.error)
                            failed = failed || !chunk.error.isEmpty
                            if chunk.completed { break }
                            try await Task.sleep(nanoseconds: 20_000_000)
                        }
                        if failed { throw KMError.device("设备脚本执行失败，错误见上方输出。") }
                    }
                default: throw KMError.invalid("未知串口命令，使用 --help 查看用法。")
                }
                signal(SIGINT, SIG_IGN)
                let interrupted = InterruptFlag()
                let task = Task {
                    let banner = try await repl.connect(path: serialPath, baud: baud)
                    FileHandle.standardError.write(Data((banner + "\n").utf8))
                    try await operation()
                }
                let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
                interrupt.setEventHandler { interrupted.set(); task.cancel() }
                interrupt.resume()
                defer { interrupt.cancel(); signal(SIGINT, SIG_DFL) }
                do {
                    try await task.value
                    if interrupted.isSet { throw CancellationError() }
                    try await repl.disconnect()
                } catch {
                    // Cleanup runs outside the cancelled task, so Ctrl-C can finish REPL recovery.
                    try? await repl.disconnect()
                    if interrupted.isSet { throw CancellationError() }
                    throw error
                }
                return
            }
            let config = try NetConfiguration(host: host, port: port, uuid: uuid,
                                              localAddress: local, timeout: timeout)
            let client = NetClient()
            var monitorOutput: FileHandle?
            defer { try? monitorOutput?.close() }
            let operation: () async throws -> Void
            switch command {
            case "connect", "release":
                guard args.count == 1 else { throw KMError.invalid("\(command) 不接受额外参数。") }
                operation = { if command == "release" { _ = try await client.releaseAll() } }
            case "move":
                guard args.count == 3, let x = Int32(args[1]), let y = Int32(args[2]),
                      (-32768...32767).contains(x), (-32768...32767).contains(y) else { throw KMError.invalid("用法：move X Y；范围 -32768…32767。") }
                operation = { _ = try await client.move(x: x, y: y) }
            case "auto-move", "bezier-move":
                let expected = command == "auto-move" ? 4 : 8
                guard args.count == expected, let x = Int32(args[1]), let y = Int32(args[2]), let ms = Int(args[3]) else {
                    throw KMError.invalid("用法：auto-move X Y 毫秒 | bezier-move X Y 毫秒 X1 Y1 X2 Y2")
                }
                let movement = try NetTimedMovement(x: x, y: y, milliseconds: ms)
                if command == "auto-move" {
                    operation = { _ = try await client.moveAutomatically(movement) }
                } else {
                    guard let x1 = Int32(args[4]), let y1 = Int32(args[5]), let x2 = Int32(args[6]), let y2 = Int32(args[7]) else {
                        throw KMError.invalid("Bézier 控制点需要整数坐标。")
                    }
                    let controls = try NetBezierControls(x1: x1, y1: y1, x2: x2, y2: y2)
                    operation = { _ = try await client.moveBezier(movement, controls: controls) }
                }
            case "click":
                guard args.count <= 2 else { throw KMError.invalid("用法：click [left|right|middle]") }
                let bit: Int32
                switch args.count == 2 ? args[1] : "left" {
                case "left": bit = 1
                case "right": bit = 2
                case "middle": bit = 4
                default: throw KMError.invalid("click 可选 left、right、middle。")
                }
                operation = { _ = try await client.click(bit) }
            case "key":
                guard args.count == 2, let key = UInt8(args[1]) else { throw KMError.invalid("用法：key USB-HID按键码") }
                var keyboard = KeyboardState(); try keyboard.set(key, down: true)
                operation = { _ = try await client.tapKey(key) }
            case "info":
                guard args.count == 1 else { throw KMError.invalid("用法：info") }
                operation = { let (info, _) = try await client.peripheralInfo(); try printJSON(info) }
            case "set-network":
                guard args.count == 3 else { throw KMError.invalid("用法：set-network 新IP 新端口；写入后需重新上电。") }
                let settings = try NetNetworkSettings(host: args[1], port: args[2])
                operation = { _ = try await client.setNetwork(settings); print("已收到写入应答；重新上电后使用新地址连接，尚未回读验证。") }
            case "set-vidpid":
                guard args.count == 3, let vid = UInt16(args[1], radix: 16), let pid = UInt16(args[2], radix: 16) else {
                    throw KMError.invalid("用法：set-vidpid VID_HEX PID_HEX（各 1–4 位，不带 0x）")
                }
                operation = { _ = try await client.setVIDPID(vendor: vid, product: pid); print("已收到 VID/PID 写入应答；实际 USB 枚举值需重新枚举后检查。") }
            case "curve":
                let settings: NetCurveSettings
                if args.count == 2 && args[1] == "off" { settings = try NetCurveSettings(enabled: false, curve: .bezier, strength: 0) }
                else {
                    guard args.count == 3, let curve = NetCurve.allCases.first(where: { $0.name.lowercased() == args[1].lowercased() }),
                          let strength = Int(args[2]) else { throw KMError.invalid("用法：curve off | bezier|arm|rt-bezier|rt-arm 强度0–100") }
                    settings = try NetCurveSettings(enabled: true, curve: curve, strength: strength)
                }
                operation = { _ = try await client.setCurve(settings); print("已收到曲线写入应答；协议未提供当前曲线回读。") }
            case "mode":
                guard args.count == 2, ["km", "bypass"].contains(args[1]) else { throw KMError.invalid("用法：mode km|bypass；重启单独执行。") }
                let bypass = args[1] == "bypass"
                operation = { _ = try await client.setBypass(bypass); print("已收到模式写入应答；需执行 reboot 或重新上电生效，尚未回读验证。") }
            case "parsing":
                guard args.count == 3, let mouse = Int(args[1]), let keyboard = Int(args[2]) else { throw KMError.invalid("用法：parsing 鼠标模式 键盘模式（0–32 或 255）") }
                let modes = try NetParsingModes(mouse: mouse, keyboard: keyboard)
                operation = { let (info, _) = try await client.setParsing(modes); try printJSON(info) }
            case "reboot":
                guard args.count == 1 else { throw KMError.invalid("用法：reboot") }
                operation = { _ = try await client.reboot(); print("已收到重启应答并关闭连接；重新上线需再次连接验证。") }
            case "hold":
                guard args.count == 3, let key = UInt8(args[1]), let duration = Double(args[2]), duration.isFinite,
                      (0.01...10).contains(duration) else { throw KMError.invalid("用法：hold USB_HID_CODE 秒数（0.01–10）") }
                var state = KeyboardState(); try state.set(key, down: true)
                operation = {
                    _ = try await client.setKey(key, down: true)
                    try await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
                    _ = try await client.setKey(key, down: false)
                }
            case "monitor":
                guard args.count <= 3, let duration = Double(args.count > 1 ? args[1] : "10"), duration.isFinite,
                      (0.1...3600).contains(duration), let listenPort = UInt16(args.count > 2 ? args[2] : "6688"),
                      (1024...49151).contains(listenPort) else { throw KMError.invalid("用法：monitor [秒数0.1–3600] [本机端口1024–49151]") }
                if !monitorOutputPath.isEmpty {
                    let fd = Darwin.open(monitorOutputPath, O_WRONLY | O_CREAT | O_EXCL, 0o600)
                    guard fd >= 0 else { throw KMError.io("无法创建监控日志（目标必须不存在）：" + String(cString: strerror(errno))) }
                    monitorOutput = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                    try monitorOutput?.write(contentsOf: NetMonitorJSONL.header())
                }
                let output = monitorOutput
                operation = {
                    _ = try await client.startMonitor(port: listenPort)
                    let deadline = DispatchTime.now().uptimeNanoseconds + UInt64(duration * 1_000_000_000)
                    var batch = try await client.readMonitor()
                    try output?.write(contentsOf: NetMonitorJSONL.records(batch.records))
                    var latest = batch.frames.last
                    while DispatchTime.now().uptimeNanoseconds < deadline {
                        try await Task.sleep(nanoseconds: 33_000_000)
                        batch = try await client.readMonitor()
                        try output?.write(contentsOf: NetMonitorJSONL.records(batch.records))
                        if let frame = batch.frames.last { latest = frame }
                    }
                    _ = try await client.stopMonitor()
                    try printJSON(MonitorSummary(accepted: batch.accepted, rejected: batch.rejected,
                                                 received: batch.received, undecodable: batch.undecodable,
                                                 foreignSource: batch.foreignSource, extended: batch.extended,
                                                 lastReceivedLength: batch.lastReceivedLength,
                                                 lastRejectedLength: batch.lastRejectedLength, latest: latest))
                }
            case "scroll":
                guard args.count == 2, let amount = Int32(args[1]), (-127...127).contains(amount) else { throw KMError.invalid("用法：scroll 步数；范围 -127…127。") }
                operation = { _ = try await client.scroll(amount) }
            default: throw KMError.invalid("未知命令。使用 --help 查看用法。")
            }
            signal(SIGINT, SIG_IGN); signal(SIGTERM, SIG_IGN)
            let interrupted = InterruptFlag()
            let task = Task {
                let receipt = try await client.connect(config)
                FileHandle.standardError.write(Data(String(format: "已收到连接应答 · %.2f ms\n", receipt.milliseconds).utf8))
                try Task.checkCancellation()
                try await operation()
            }
            let signals = [SIGINT, SIGTERM].map { number -> DispatchSourceSignal in
                let source = DispatchSource.makeSignalSource(signal: number, queue: .global())
                source.setEventHandler { interrupted.set(); task.cancel() }; source.resume(); return source
            }
            defer { signals.forEach { $0.cancel() }; signal(SIGINT, SIG_DFL); signal(SIGTERM, SIG_DFL) }
            var failure: Error?
            do { try await task.value } catch { failure = error }
            do { try await client.disconnect() }
            catch {
                FileHandle.standardError.write(Data(("连接清理未确认：" + error.localizedDescription + "\n").utf8))
                if failure == nil { failure = error }
            }
            do { try monitorOutput?.synchronize(); try monitorOutput?.close(); monitorOutput = nil }
            catch {
                FileHandle.standardError.write(Data(("监控日志保存失败：" + error.localizedDescription + "\n").utf8))
                if failure == nil { failure = error }
            }
            if showStats {
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                let data = try encoder.encode(["netStatistics": await client.statistics()])
                try FileHandle.standardError.write(contentsOf: data + Data([10]))
            }
            if interrupted.isSet { throw CancellationError() }
            if let failure { throw failure }

        } catch {
            if error is CancellationError { exit(130) }
            FileHandle.standardError.write(Data((error.localizedDescription + "\n").utf8))
            exit(1)
        }
    }

    static let help = """
    固件离线检查：firmware-check NB固件.cpio
    固件下载服务：--local Mac网卡IPv4 [--host NB的IPv4] firmware-serve NB固件.cpio
    默认 TCP 80；--host 为可选来源限制；Ctrl-C 停止；由盒子升级页发起下载和刷写。
    串口可加 --baud 波特率（默认 115200）。

    KMBox Mac command line
      kmctl interfaces | ports
      kmctl --host IP [--local IP] ping         ICMP 单次诊断（JSON，不建立 Net 会话）
      kmctl --host IP [--local IP] chip-id      UDP 1752 芯片查询（JSON，不建立 Net 会话）
      kmctl --host IP --port PORT --uuid HEX [--local IP] [--timeout 1] connect
      kmctl --host IP --port PORT --uuid HEX move X Y
      kmctl --host IP --port PORT --uuid HEX click [left|right|middle]
      kmctl --host IP --port PORT --uuid HEX key USB_HID_CODE
      kmctl --host IP --port PORT --uuid HEX scroll STEPS
      kmctl --host IP --port PORT --uuid HEX release
      下列命令同样需要 --host / --port / --uuid；多网卡时使用 --local。
      --stats                           操作结束后向 stderr 输出 Net 应答统计 JSON（包括失败与清理）
      auto-move X Y MS                   自动相对移动；时长 1–10000 毫秒
      bezier-move X Y MS X1 Y1 X2 Y2     Bézier 相对移动；坐标范围 -32768…32767
      定时移动是单次请求，不修改 AI 配置；应答等待上限为请求时长加 --timeout。
      info                              读取外设标识与解析模式（JSON）
      set-network NEW_IP NEW_PORT        写入网络设置，重新上电生效
      set-vidpid VID_HEX PID_HEX          写入 USB 标识（十六进制，不带 0x）
      curve off | TYPE STRENGTH          TYPE: bezier/arm/rt-bezier/rt-arm
      curve 使用原 Net 工具固定编号；不是 NB 的算法列表，AI / 当前曲线 / 阈值尚未实现网络读取。
      mode km|bypass                     写入工作模式，重启单独执行
      parsing MOUSE KEYBOARD             修改解析模式并回读；0–32 或 255
      reboot                             释放保持按键、停止监控并重启
      monitor [SECONDS] [PORT]           设备上报统计，默认 10 秒 / 6688；Ctrl-C 清理
      monitor 可加 --monitor-output 新文件.jsonl，持续写入原始报文和 Mac 接收时间；不覆盖现有文件。
      hold USB_HID_CODE SECONDS           保持 0.01–10 秒；Ctrl-C 释放
      kmctl --serial /dev/cu.DEVICE ls [REMOTE_DIRECTORY]
      kmctl --serial /dev/cu.DEVICE cat REMOTE_FILE
      kmctl --serial /dev/cu.DEVICE put LOCAL_FILE REMOTE_FILE [--replace]
      kmctl --serial /dev/cu.DEVICE get REMOTE_FILE LOCAL_FILE [--replace]
      kmctl --serial /dev/cu.DEVICE mkdir REMOTE_DIRECTORY
      kmctl --serial /dev/cu.DEVICE mv OLD_REMOTE_PATH NEW_REMOTE_PATH
      kmctl --serial /dev/cu.DEVICE rm REMOTE_FILE
      kmctl --serial /dev/cu.DEVICE rmdir EMPTY_REMOTE_DIRECTORY
      kmctl --serial /dev/cu.DEVICE exec 'print(1 + 1)'
      kmctl --serial /dev/cu.DEVICE run LOCAL_FILE.py

    串口命令会中断盒内正在运行的脚本；固件服务由盒子升级页主动取文件。
    """
}

private final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
}

private struct MonitorSummary: Encodable {
    let accepted: UInt64
    let rejected: UInt64
    let received: UInt64
    let undecodable: UInt64
    let foreignSource: UInt64
    let extended: UInt64
    let lastReceivedLength: Int?
    let lastRejectedLength: Int?
    let latest: NetMonitorFrame?
}

private func printJSON<T: Encodable>(_ value: T) throws {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(value) + Data([10]))
}
