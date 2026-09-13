import AppKit
import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers
import KMBoxCore

struct VideoSource: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let formats: [VideoFormat]
}

struct VideoFormat: Identifiable, Equatable, Sendable {
    let id: Int
    let width: Int32
    let height: Int32
    let codec: String
    let rates: [Double]
    var name: String { "\(width) × \(height) · \(codec) · \(rates.map { String(format: "%g", $0) }.joined(separator: "/")) fps" }
}

enum SnapshotFormat: String, CaseIterable, Identifiable, Sendable {
    case png, jpeg, bmp, tiff
    var id: String { rawValue }
    var type: UTType { switch self { case .png: return .png; case .jpeg: return .jpeg; case .bmp: return .bmp; case .tiff: return .tiff } }
    static func encode(_ image: CGImage, as format: SnapshotFormat) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, format.type.identifier as CFString, 1, nil) else {
            throw KMError.io("无法创建截图编码器。")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw KMError.io("截图编码失败。") }
        return data as Data
    }
}

struct MousePressEdge {
    private var previous: Bool?
    mutating func consume(buttons: UInt8) -> Bool {
        let down = buttons & 1 != 0
        defer { previous = down }
        return previous == false && down
    }
    mutating func reset() { previous = nil }
}

@MainActor
final class CaptureModel: ObservableObject {
    @Published private(set) var sources: [VideoSource] = []
    @Published private(set) var formats: [VideoFormat] = []
    @Published var sourceID = ""
    @Published var formatID = -1
    @Published var rate = 60.0
    @Published private(set) var running = false
    @Published private(set) var busy = false
    @Published private(set) var frameAvailable = false
    @Published private(set) var measuredRate = 0.0
    @Published private(set) var message = "选择接到 Mac 的采集卡或摄像头，点击开始预览。"
    @Published private(set) var error = ""
    @Published var snapshotFormat = SnapshotFormat.png
    @Published var automatic = false { didSet { edge.reset() } }
    @Published private(set) var folder: URL?
    @Published private(set) var saved = 0
    @Published private(set) var skipped = 0
    @Published private(set) var saving = false
    private var edge = MousePressEdge()
    private let worker: CaptureWorker
    private let discoverSources: @Sendable () async -> [VideoSource]
    private var hasDiscovered = false
    private var operation: Task<Void, Never>?
    private var snapshotTask: Task<Void, Never>?
    private var generation = UUID()
    var session: AVCaptureSession { worker.session }
    var selectedFormat: VideoFormat? { formats.first { $0.id == formatID } }

    init(discoverSources: (@Sendable () async -> [VideoSource])? = nil) {
        let worker = CaptureWorker()
        self.worker = worker
        self.discoverSources = discoverSources ?? { await worker.discover() }
        worker.setUpdate { [weak self] rate, available, failure in
            Task { @MainActor [weak self] in
                guard let self, self.running else { return }
                self.measuredRate = rate; self.frameAvailable = available
                if let failure { self.error = failure; self.stop() }
            }
        }
    }

    func refreshIfNeeded() {
        if !hasDiscovered { refresh() }
    }

    func refresh() {
        guard !busy, !running else { return }
        busy = true
        let token = generation
        operation = Task {
            let discovered = await discoverSources()
            guard !Task.isCancelled, token == generation else { return }
            let previousSource = sourceID
            sources = discovered
            if !sources.contains(where: { $0.id == sourceID }) { sourceID = sources.first?.id ?? "" }
            busy = false; hasDiscovered = true
            selectSource(preserveSelection: previousSource == sourceID)
            message = sources.isEmpty ? "未找到 Mac 可用的视频采集设备。请连接采集卡后刷新。" : "选择接到 Mac 的采集卡或摄像头，点击开始预览。"
        }
    }

    func selectSource(preserveSelection: Bool = false) {
        guard !busy, !running else { return }
        guard let source = sources.first(where: { $0.id == sourceID }) else {
            formats = []; formatID = -1; return
        }
        let previousFormat = selectedFormat
        formats = source.formats
        if preserveSelection, let previousFormat, formats.contains(previousFormat) {
            if !previousFormat.rates.contains(rate) { selectFormat() }
            return
        }
        formatID = formats.first(where: { $0.width == 1920 && $0.height == 1080 })?.id ?? formats.first?.id ?? -1
        selectFormat()
    }

    func selectFormat() { rate = selectedFormat?.rates.last(where: { $0 <= 60 }) ?? selectedFormat?.rates.first ?? 30 }

    func start() {
        guard !busy, !running, !sourceID.isEmpty, selectedFormat != nil else { return }
        busy = true; error = ""; frameAvailable = false; generation = UUID()
        let token = generation, source = sourceID, format = formatID, fps = rate
        operation = Task {
            do {
                let allowed: Bool
                switch AVCaptureDevice.authorizationStatus(for: .video) {
                case .authorized: allowed = true
                case .notDetermined: allowed = await AVCaptureDevice.requestAccess(for: .video)
                default: allowed = false
                }
                guard token == generation else { return }
                guard allowed else { throw KMError.io("尚未获得相机权限。请在系统设置 → 隐私与安全性 → 相机中允许 KMBox Mac。") }
                try await worker.start(source: source, formatIndex: format, fps: fps)
                guard token == generation else { await worker.stop(); return }
                running = true; busy = false; edge.reset()
                message = "预览已启动，等待视频帧。截图保存在 Mac。"
            } catch { guard token == generation else { return }; self.error = error.localizedDescription; busy = false; running = false }
        }
    }

    func stop() {
        guard !busy else { return }
        busy = true; running = false; automatic = false; frameAvailable = false; measuredRate = 0
        operation = Task { await worker.stop(); busy = false; message = "预览已停止。" }
    }

    func chooseFolder() {
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true
        panel.prompt = "选择截图目录"
        if panel.runModal() == .OK { folder = panel.url }
    }

    func saveSnapshot() {
        guard running, frameAvailable, !saving else { return }
        let panel = NSSavePanel(); panel.allowedContentTypes = [snapshotFormat.type]
        panel.nameFieldStringValue = "KMBox-\(Int(Date().timeIntervalSince1970)).\(snapshotFormat.rawValue)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        save(to: url, replace: true)
    }

    func receiveMouse(_ frame: NetMonitorFrame) {
        guard automatic, running else { return }
        guard edge.consume(buttons: frame.buttons) else { return }
        guard let folder else { automatic = false; return }
        if saving { skipped += 1; return }
        guard frameAvailable else { skipped += 1; return }
        save(to: folder.appendingPathComponent("KMBox-\(UUID().uuidString).\(snapshotFormat.rawValue)"), replace: false)
    }
    func monitorStopped() { automatic = false; edge.reset() }

    private func save(to url: URL, replace: Bool) {
        saving = true; error = ""
        let format = snapshotFormat
        snapshotTask = Task {
            do {
                try await worker.save(to: url, format: format, replace: replace)
                saved += 1; message = "已保存：\(url.path)"
            } catch { self.error = error.localizedDescription }
            saving = false
        }
    }

    func shutdown() async {
        generation = UUID(); automatic = false; running = false
        operation?.cancel()
        // A permission sheet may outlive the app; the generation prevents a late start.
        await worker.stop()
        await snapshotTask?.value
        busy = false; frameAvailable = false
    }
}

/// Session configuration, frame ownership and image encoding share one serial queue.
private final class CaptureWorker: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    let session = AVCaptureSession()
    let queue = DispatchQueue(label: "local.kmbox.capture", qos: .userInitiated)
    private var update: (@Sendable (Double, Bool, String?) -> Void)?
    private let context = CIContext()
    private var latest: CVPixelBuffer?
    private var latestAt: TimeInterval = 0
    private var count = 0
    private var interval: TimeInterval = 0
    private var observer: NSObjectProtocol?
    private var disconnectedObserver: NSObjectProtocol?
    private var timer: DispatchSourceTimer?

    override init() {
        super.init()
        observer = NotificationCenter.default.addObserver(forName: .AVCaptureSessionRuntimeError, object: session, queue: nil) { [weak self] notification in
            let message = (notification.userInfo?[AVCaptureSessionErrorKey] as? Error)?.localizedDescription ?? "视频采集发生运行错误。"
            self?.queue.async { [weak self] in self?.update?(0, false, message) }
        }
        disconnectedObserver = NotificationCenter.default.addObserver(forName: AVCaptureDevice.wasDisconnectedNotification, object: nil, queue: nil) { [weak self] notification in
            let id = (notification.object as? AVCaptureDevice)?.uniqueID
            self?.queue.async { [weak self] in
                guard let self, self.session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device.uniqueID == id }) else { return }
                self.update?(0, false, "视频采集设备已断开。")
            }
        }
    }
    deinit {
        timer?.cancel()
        if let observer { NotificationCenter.default.removeObserver(observer) }
        if let disconnectedObserver { NotificationCenter.default.removeObserver(disconnectedObserver) }
    }
    func setUpdate(_ handler: @escaping @Sendable (Double, Bool, String?) -> Void) { queue.async { self.update = handler } }

    func discover() async -> [VideoSource] {
        await withCheckedContinuation { continuation in queue.async {
            let sources = videoDevices().map { device in
                let formats = device.formats.enumerated().map { index, format in
                    let dimensions = CMVideoFormatDescriptionGetDimensions(format.formatDescription)
                    let code = CMFormatDescriptionGetMediaSubType(format.formatDescription)
                    let codec = String(bytes: (0..<4).reversed().map { UInt8(truncatingIfNeeded: code >> ($0 * 8)) }, encoding: .ascii) ?? String(code)
                    let ranges = format.videoSupportedFrameRateRanges
                    let candidates: [Double] = [15, 24, 25, 29.97, 30, 50, 59.94, 60, 120] + ranges.flatMap { [$0.minFrameRate, $0.maxFrameRate] }
                    let rates = Array(Set(candidates.filter { value in ranges.contains { value >= $0.minFrameRate && value <= $0.maxFrameRate } })).sorted()
                    return VideoFormat(id: index, width: dimensions.width, height: dimensions.height, codec: codec, rates: rates)
                }
                return VideoSource(id: device.uniqueID, name: device.localizedName, formats: formats)
            }
            continuation.resume(returning: sources)
        } }
    }

    func start(source: String, formatIndex: Int, fps: Double) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async { [self] in
                do {
                    guard let device = videoDevices().first(where: { $0.uniqueID == source }), device.formats.indices.contains(formatIndex) else {
                        throw KMError.io("所选采集设备或格式已不可用，请刷新设备列表。")
                    }
                    let format = device.formats[formatIndex]
                    guard fps.isFinite, fps > 0, let rateRange = format.videoSupportedFrameRateRanges.first(where: { fps >= $0.minFrameRate && fps <= $0.maxFrameRate }) else { throw KMError.invalid("所选格式不支持该帧率。") }
                    let input = try AVCaptureDeviceInput(device: device)
                    session.beginConfiguration()
                    session.inputs.forEach { session.removeInput($0) }; session.outputs.forEach { session.removeOutput($0) }
                    do {
                        guard session.canAddInput(input) else { throw KMError.io("无法使用所选视频输入。") }
                        session.addInput(input)
                        try device.lockForConfiguration()
                        device.activeFormat = format
                        // Reuse exact rational endpoints; rounding 1/60 can exceed a fixed 60 fps format.
                        let duration: CMTime
                        if fps == rateRange.maxFrameRate { duration = rateRange.minFrameDuration }
                        else if fps == rateRange.minFrameRate { duration = rateRange.maxFrameDuration }
                        else { duration = CMTimeMaximum(rateRange.minFrameDuration, CMTimeMinimum(rateRange.maxFrameDuration, CMTime(seconds: 1 / fps, preferredTimescale: 1_000_000_000))) }
                        device.activeVideoMinFrameDuration = duration; device.activeVideoMaxFrameDuration = duration
                        device.unlockForConfiguration()
                        let output = AVCaptureVideoDataOutput()
                        output.alwaysDiscardsLateVideoFrames = true
                        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
                        output.setSampleBufferDelegate(self, queue: queue)
                        guard session.canAddOutput(output) else { throw KMError.io("无法创建视频帧输出。") }
                        session.addOutput(output); session.commitConfiguration()
                    } catch { session.commitConfiguration(); throw error }
                    latest = nil; count = 0; interval = ProcessInfo.processInfo.systemUptime
                    session.startRunning()
                    guard session.isRunning else { throw KMError.io("视频采集未启动，设备可能正被其他程序占用。") }
                    timer?.cancel()
                    let timer = DispatchSource.makeTimerSource(queue: queue)
                    timer.schedule(deadline: .now() + 2, repeating: 1)
                    timer.setEventHandler { [weak self] in
                        guard let self else { return }
                        if ProcessInfo.processInfo.systemUptime - self.latestAt > 2 { self.update?(0, false, nil) }
                    }
                    self.timer = timer; timer.resume()
                    continuation.resume()
                } catch {
                    session.stopRunning()
                    session.beginConfiguration()
                    session.inputs.forEach { session.removeInput($0) }; session.outputs.forEach { session.removeOutput($0) }
                    session.commitConfiguration(); latest = nil
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    func stop() async {
        await withCheckedContinuation { continuation in queue.async { [self] in
            timer?.cancel(); timer = nil
            session.stopRunning(); session.beginConfiguration()
            session.inputs.forEach { session.removeInput($0) }; session.outputs.forEach { session.removeOutput($0) }
            session.commitConfiguration(); latest = nil
            continuation.resume()
        } }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard session.isRunning, let image = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latest = image; latestAt = ProcessInfo.processInfo.systemUptime; count += 1
        if latestAt - interval >= 1 || count == 1 {
            update?(Double(count) / max(0.001, latestAt - interval), true, nil)
            if latestAt - interval >= 1 { count = 0; interval = latestAt }
        }
    }

    func save(to url: URL, format: SnapshotFormat, replace: Bool) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in queue.async { [self] in
            do {
                guard session.isRunning, let latest, ProcessInfo.processInfo.systemUptime - latestAt < 2 else { throw KMError.io("没有最近两秒的视频帧，无法截图。") }
                let source = CIImage(cvPixelBuffer: latest)
                guard let image = context.createCGImage(source, from: source.extent) else { throw KMError.io("无法读取视频帧。") }
                let data = try SnapshotFormat.encode(image, as: format)
                try data.write(to: url, options: replace ? .atomic : .withoutOverwriting)
                continuation.resume()
            } catch { continuation.resume(throwing: error) }
        } }
    }
}

private func videoDevices() -> [AVCaptureDevice] {
    let types: [AVCaptureDevice.DeviceType]
    if #available(macOS 14, *) { types = [.builtInWideAngleCamera, .external] }
    else { types = [.builtInWideAngleCamera, .externalUnknown] }
    return AVCaptureDevice.DiscoverySession(deviceTypes: types, mediaType: .video, position: .unspecified).devices
}
