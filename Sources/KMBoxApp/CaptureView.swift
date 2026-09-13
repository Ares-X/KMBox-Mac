import SwiftUI
import AVFoundation

struct CaptureView: View {
    @ObservedObject var capture: CaptureModel
    let monitorListening: Bool
    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Panel(title: "视频采集", icon: "video") {
                    Picker("采集设备", selection: $capture.sourceID) {
                        if capture.sources.isEmpty { Text("未找到设备").tag("") }
                        ForEach(capture.sources) { Text($0.name).tag($0.id) }
                    }.onChange(of: capture.sourceID) { _ in capture.selectSource() }
                        .disabled(capture.running || capture.busy)
                    Picker("原生输入格式", selection: $capture.formatID) {
                        if capture.formats.isEmpty { Text("未选择格式").tag(-1) }
                        ForEach(capture.formats) { Text($0.name).tag($0.id) }
                    }.onChange(of: capture.formatID) { _ in capture.selectFormat() }
                        .disabled(capture.running || capture.busy)
                    HStack {
                        Picker("帧率", selection: $capture.rate) {
                            ForEach(capture.selectedFormat?.rates ?? [30], id: \.self) { Text(String(format: "%g fps", $0)).tag($0) }
                        }.frame(width: 220).disabled(capture.running || capture.busy)
                        Button("刷新设备") { capture.refresh() }.disabled(capture.running || capture.busy)
                        Spacer()
                        if capture.busy { ProgressView().controlSize(.small) }
                        Button(capture.running ? "停止预览" : "开始预览") { capture.running ? capture.stop() : capture.start() }
                            .disabled(capture.busy || capture.sourceID.isEmpty).buttonStyle(.borderedProminent)
                    }
                    VideoPreview(session: capture.session).frame(height: 320).background(.black)
                        .overlay(alignment: .bottomLeading) {
                            Text(capture.running ? String(format: "实际 %.1f fps", capture.measuredRate) : "预览未启动")
                                .font(.caption.monospaced()).padding(8).foregroundStyle(.white).background(.black.opacity(0.6))
                        }
                    Text("采集源来自接入 Mac 的视频设备；分辨率、像素格式与帧率按设备实际提供的能力列出。此功能不通过 Net 键鼠协议读取盒子屏幕，也不采集声音。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Panel(title: "截图", icon: "camera") {
                    HStack {
                        Picker("图像格式", selection: $capture.snapshotFormat) { ForEach(SnapshotFormat.allCases) { Text($0.rawValue.uppercased()).tag($0) } }.frame(width: 200)
                        Button("保存当前帧…") { capture.saveSnapshot() }.disabled(!capture.running || !capture.frameAvailable || capture.saving)
                        Spacer()
                        Text("已保存 \(capture.saved) · 忙时跳过 \(capture.skipped)").font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        Button("选择自动截图目录…") { capture.chooseFolder() }
                        Text(capture.folder?.path ?? "尚未选择").font(.caption).textSelection(.enabled).lineLimit(2)
                    }
                    Toggle("收到设备上报的左键按下时截图", isOn: $capture.automatic)
                        .disabled(!monitorListening || !capture.running || capture.folder == nil)
                    Text("先在“配置与监控”启动上报。每次松开后重新按下左键保存一张；持续按住不会重复保存，最初收到的已按下状态不触发。停止监控或预览会关闭自动截图。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                MessageBanner(text: capture.message)
                if !capture.error.isEmpty { MessageBanner(text: capture.error, error: true) }
            }.padding(24)
        }.task { capture.refresh() }
    }
}

private final class PreviewSurface: NSView {
    let preview = AVCaptureVideoPreviewLayer()
    override init(frame: NSRect) {
        super.init(frame: frame); wantsLayer = true; layer = CALayer()
        preview.videoGravity = .resizeAspect; layer?.addSublayer(preview)
    }
    required init?(coder: NSCoder) { nil }
    override func layout() { super.layout(); preview.frame = bounds }
}

private struct VideoPreview: NSViewRepresentable {
    let session: AVCaptureSession
    func makeNSView(context: Context) -> PreviewSurface { let view = PreviewSurface(); view.preview.session = session; return view }
    func updateNSView(_ view: PreviewSurface, context: Context) { if view.preview.session !== session { view.preview.session = session } }
}
