import SwiftUI
import KMBoxCore

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?
    private var quitting = false
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !quitting else { return .terminateNow }
        if model?.firmwareActive == true {
            let alert = NSAlert(); alert.messageText = "NB 固件服务仍在运行"
            alert.informativeText = "退出会停止下载服务。请先确认盒子已完成下载与升级。"
            alert.addButton(withTitle: "留在应用"); alert.addButton(withTitle: "退出并停止服务")
            guard alert.runModal() == .alertSecondButtonReturn else { return .terminateCancel }
        }
        quitting = true
        Task {
            let failures = await model?.shutdown() ?? []
            var shouldQuit = true
            if !failures.isEmpty {
                let alert = NSAlert(); alert.messageText = "未能确认设备已经停止 / 释放"
                alert.informativeText = failures.joined(separator: "\n") + "\n可留在应用，重新连接设备检查状态。"
                alert.addButton(withTitle: "留在应用"); alert.addButton(withTitle: "仍然退出")
                shouldQuit = alert.runModal() == .alertSecondButtonReturn
            }
            quitting = shouldQuit
            sender.reply(toApplicationShouldTerminate: shouldQuit)
        }
        return .terminateLater
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

@main
struct KMBoxMacApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(ApplicationDelegate.self) private var delegate
    var body: some Scene {
        WindowGroup("KMBox Mac") {
            ContentView().environmentObject(model)
                .frame(minWidth: 1040, minHeight: 720)
                .onAppear { delegate.model = model }
                .onOpenURL { url in
                    if url.isFileURL { model.openLocal(url) }
                }
        }
        .defaultSize(width: 1200, height: 820)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建 Python 文件") { model.newDocument() }.keyboardShortcut("n")
                Button("打开文件…") { model.chooseFile() }.keyboardShortcut("o")
                Button("打开工作区…") { model.chooseWorkspace() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .saveItem) {
                Button("保存到 Mac") { model.saveLocal() }.keyboardShortcut("s")
                Button("另存为…") { model.saveLocal(asNew: true) }.keyboardShortcut("s", modifiers: [.command, .shift])
            }
            CommandGroup(after: .textEditing) {
                Divider()
                Button("查找与替换…") { showFind() }.keyboardShortcut("f")
                Button("切换行注释") { (NSApp.keyWindow?.firstResponder as? PythonTextView)?.toggleComment(nil) }.keyboardShortcut("/")
                Button("增加缩进") { (NSApp.keyWindow?.firstResponder as? PythonTextView)?.indentSelection(nil) }.keyboardShortcut("]")
                Button("减少缩进") { (NSApp.keyWindow?.firstResponder as? PythonTextView)?.unindentSelection(nil) }.keyboardShortcut("[")
            }
            CommandMenu("设备") {
                Button("运行编辑区") { model.runEditor() }.keyboardShortcut("r").disabled(!model.canUseBoard)
                Button("上传并运行") { model.upload(runAfter: true) }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(!model.canUseBoard)
                Button("停止脚本") { model.stopBoard() }.keyboardShortcut(".").disabled(!model.boardRunning && !model.boardBusy)
                Divider()
                Button("全部释放键鼠") { model.releaseAll() }.keyboardShortcut(.escape, modifiers: [.command]).disabled(!model.netConnected)
                Button("语法检查") { model.checkSyntax() }.keyboardShortcut("b").disabled(model.activeDocument == nil)
            }
            CommandMenu("示例") {
                Button("设备信息") { model.newDocument(name: "hello_nb.py", text: AppModel.exampleInfo) }
                Button("循环与停止") { model.newDocument(name: "loop.py", text: AppModel.exampleLoop) }
                Button("检查可用模块") { model.newDocument(name: "modules.py", text: AppModel.exampleModules) }
            }
            CommandGroup(replacing: .help) {
                Button("KMBox Mac 使用说明") {
                    if let url = Bundle.main.url(forResource: "README", withExtension: "md") { NSWorkspace.shared.open(url) }
                }
                Button("KMBox NB 官方文档") { NSWorkspace.shared.open(URL(string: "https://www.kmbox.top/wiki_doc/kmboxNB/site/")!) }
                Button("KMBox Net 连接与功能教程") { NSWorkspace.shared.open(URL(string: "https://www.kmbox.top/wiki_doc/kmboxNet/site/")!) }
                Button("NB 三路轨迹说明") { NSWorkspace.shared.open(URL(string: "https://www.kmbox.top/wiki_doc/kmboxNB/site/022-Trace/")!) }
                Button("打开设备固件说明") { NSWorkspace.shared.open(model.deviceModel.firmwareURL) }
            }
        }
        Settings {
            Form {
                Section("编辑器") {
                    Slider(value: $model.fontSize, in: 11...22, step: 1) { Text("字号 \(Int(model.fontSize))") }
                    Text("UTF-8 · 4 空格缩进 · 自动保存本机草稿").foregroundStyle(.secondary)
                }
                Section("串口") {
                    Picker("波特率", selection: $model.serialBaud) {
                        ForEach(SerialREPL.supportedBaudRates, id: \.self) { Text(String($0)).tag($0) }
                    }.disabled(model.boardConnected || model.boardBusy)
                    Text("NB 默认使用 115200。更改需与盒子设置一致。").font(.caption).foregroundStyle(.secondary)
                }
                Section("关于") {
                    Text("KMBox Mac 1.2.0 · 原生 macOS 开发工作台")
                    Text("网络控制使用 Net 协议；板载脚本使用 B 串口。应用不会自动刷写固件。").font(.caption).foregroundStyle(.secondary)
                    Button("初始化应用配置…") { model.resetPreferences() }
                        .disabled(model.netConnected || model.boardConnected || model.netBusy || model.boardBusy || model.firmwareActive)
                }
            }.formStyle(.grouped).frame(width: 490, height: 390)
                .onChange(of: model.fontSize) { _ in model.scheduleSave() }
                .onChange(of: model.serialBaud) { _ in model.scheduleSave() }
        }
    }
}

@MainActor
func showFind() {
    let item = NSMenuItem(); item.tag = NSTextFinder.Action.showFindInterface.rawValue
    NSApp.sendAction(#selector(NSTextView.performFindPanelAction(_:)), to: nil, from: item)
}
