import SwiftUI
import AppKit
import KMBoxCore

struct EditorView: View {
    @EnvironmentObject var model: AppModel
    @State private var browser = 0

    var body: some View {
        VStack(spacing: 0) {
            connectionBar
            if !model.boardError.isEmpty {
                MessageBanner(text: model.boardError, error: true).padding(.horizontal, 14).padding(.bottom, 9)
            }
            Divider()
            HSplitView {
                files.frame(minWidth: 200, idealWidth: 230, maxWidth: 280)
                VSplitView {
                    editor.frame(minHeight: 180, idealHeight: 420)
                    console.frame(minHeight: 145, idealHeight: 230)
                }.frame(minWidth: 500)
            }
        }
    }

    private var connectionBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Label("B 串口", systemImage: "cable.connector").font(.callout.weight(.medium))
                TextField("/dev/cu.usbmodem…", text: $model.serialPath)
                    .textFieldStyle(.roundedBorder).font(.system(size: 12, design: .monospaced))
                    .disabled(model.boardConnected || model.boardBusy)
                    .accessibilityLabel("串口路径")
                Menu {
                    ForEach(model.serialPorts, id: \.self) { path in
                        Button(path) { model.serialPath = path }
                    }
                    Divider()
                    Button("刷新端口") { model.refreshInterfaces() }
                } label: { Image(systemName: "list.bullet") }
                    .frame(width: 40).disabled(model.boardConnected || model.boardBusy).help("选择串口")
                if model.boardBusy { ProgressView().controlSize(.small) }
                Button(model.boardConnected ? "断开串口" : "连接串口") {
                    if model.boardConnected { model.disconnectBoard() } else { model.connectBoard() }
                }.buttonStyle(.borderedProminent).tint(brandFill).disabled(model.boardBusy || model.boardRunning || model.serialPath.isEmpty || model.firmwareActive || !model.deviceModel.supportsSerialREPL)
            }
            Text(model.boardConnected ? model.boardMessage : (model.deviceModel == .nb ? "在 NB 上开启 B 串口 / Python，再将对应 USB 口接到 Mac。连接会中断盒内当前脚本。USB 网卡用于网络控制。" : model.deviceModel.compatibility + " 连接串口会中断盒内当前脚本。"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).textSelection(.enabled)
        }.padding(.horizontal, 16).padding(.vertical, 13)
    }

    private var files: some View {
        VStack(spacing: 0) {
            Picker("文件位置", selection: $browser) {
                Text("Mac 工作区").tag(0)
                Text("板载文件").tag(1)
            }.pickerStyle(.segmented).padding(10)
            if browser == 0 { localFiles } else { boardFiles }
        }.background(Color(nsColor: .controlBackgroundColor))
    }

    private var localFiles: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { model.chooseWorkspace() } label: { Image(systemName: "folder.badge.plus") }.help("选择工作区")
                Button {
                    if let directory = model.workspaceDirectory { model.workspaceDirectory = directory.deletingLastPathComponent(); model.refreshLocal() }
                } label: { Image(systemName: "arrow.up") }.disabled(model.workspaceDirectory == nil).help("上级文件夹")
                Button { model.refreshLocal() } label: { Image(systemName: "arrow.clockwise") }.help("刷新本地文件")
                Spacer()
                Button { model.createLocalDirectory() } label: { Image(systemName: "plus") }.disabled(model.workspaceDirectory == nil).help("新建本地文件夹")
            }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 7)
            if let directory = model.workspaceDirectory {
                Text(directory.path).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).frame(maxWidth: .infinity, alignment: .leading).padding(10).help(directory.path)
                Divider()
                List(model.localEntries) { entry in
                    Button { model.openLocalEntry(entry) } label: {
                        fileRow(entry.name, directory: entry.isDirectory)
                    }.buttonStyle(.plain)
                    .contextMenu {
                        Button("打开") { model.openLocalEntry(entry) }
                        Button("在 Finder 中显示") { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) }
                        Divider()
                        Button("重命名…") { model.renameLocal(entry) }
                        Button("移到废纸篓…") { model.trashLocal(entry) }
                    }
                }.listStyle(.plain)
            } else {
                VStack(spacing: 13) {
                    Image(systemName: "folder").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("选择本地文件夹\n集中管理 Python 脚本").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("选择工作区…") { model.chooseWorkspace() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private var boardFiles: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    let parent = (model.boardDirectory as NSString).deletingLastPathComponent
                    model.enterBoardDirectory(parent.isEmpty ? "/" : parent)
                } label: { Image(systemName: "arrow.up") }.help("上级板载文件夹")
                Button { model.refreshBoard() } label: { Image(systemName: "arrow.clockwise") }.help("刷新板载文件")
                Spacer()
                Button { model.createBoardDirectory() } label: { Image(systemName: "folder.badge.plus") }.help("新建板载文件夹")
            }.buttonStyle(.borderless).padding(.horizontal, 12).padding(.vertical, 7).disabled(!model.canUseBoard)
            Text(model.boardDirectory).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                .lineLimit(2).frame(maxWidth: .infinity, alignment: .leading).padding(10).textSelection(.enabled)
            Divider()
            if model.boardConnected {
                List(model.boardEntries) { entry in
                    Button { model.openBoardEntry(entry) } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            fileRow(entry.name, directory: entry.isDirectory)
                            if !entry.isDirectory { Text(ByteCountFormatter.string(fromByteCount: Int64(entry.size), countStyle: .file)).font(.system(size: 10)).foregroundStyle(.tertiary).padding(.leading, 24) }
                        }
                    }.buttonStyle(.plain).disabled(!model.canUseBoard)
                        .contextMenu {
                            Button("打开") { model.openBoardEntry(entry) }
                            if !entry.isDirectory {
                                Button("从设备重新读取…") { model.openBoardEntry(entry, reload: true) }
                                Button("下载到 Mac…") { model.downloadBoard(entry) }
                                Button("运行此文件") { model.runFile(entry) }
                                Button("设为启动脚本…") { model.setStartup(entry) }
                            }
                            Divider()
                            Button("重命名…") { model.renameBoard(entry) }
                            Button("删除…") { model.deleteBoard(entry) }
                        }
                }.listStyle(.plain).disabled(!model.canUseBoard)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "externaldrive").font(.system(size: 30)).foregroundStyle(.tertiary)
                    Text("连接 B 串口后\n读取盒内文件").font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func fileRow(_ name: String, directory: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: directory ? "folder.fill" : "doc.text").foregroundStyle(directory ? accent : .secondary).frame(width: 16)
            Text(name).font(.system(size: 12)).lineLimit(1).truncationMode(.middle)
            Spacer(minLength: 0)
        }.padding(.vertical, 3).contentShape(Rectangle())
    }

    private var editor: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    ForEach(model.documents) { document in
                        HStack(spacing: 7) {
                            Button { model.selectDocument(document.id) } label: {
                                HStack(spacing: 6) {
                                    Image(systemName: document.remotePath == nil ? "doc.text" : "externaldrive")
                                    Text(document.name).lineLimit(1)
                                    if document.dirty { Circle().fill(accent).frame(width: 5, height: 5) }
                                }.font(.system(size: 12))
                            }.buttonStyle(.plain)
                            Button { model.closeDocument(document.id) } label: { Image(systemName: "xmark").font(.system(size: 9)) }
                                .buttonStyle(.plain).foregroundStyle(.secondary).help("关闭 \(document.name)")
                        }.padding(.horizontal, 13).padding(.vertical, 12)
                            .background(model.selectedDocument == document.id ? Color(nsColor: .textBackgroundColor) : .clear)
                            .overlay(alignment: .bottom) { if model.selectedDocument == document.id { accent.frame(height: 2) } }
                    }
                    Button { model.newDocument() } label: { Image(systemName: "plus") }.buttonStyle(.borderless).padding(12).help("新建 Python 文件")
                }
            }.frame(height: 40).background(Color(nsColor: .windowBackgroundColor))
            Divider()
            if let document = model.activeDocument {
                HStack(spacing: 9) {
                    Button { showFind() } label: { Image(systemName: "magnifyingglass") }.help("查找与替换 · ⌘F")
                    Button("语法检查") { model.checkSyntax() }.help("⌘B")
                    Spacer()
                    Button("上传") { model.upload() }.disabled(!model.canUseBoard)
                    Button("上传并运行") { model.upload(runAfter: true) }.disabled(!model.canUseBoard)
                    Button { model.runEditor() } label: { Label("运行", systemImage: "play.fill") }
                        .buttonStyle(.borderedProminent).tint(brandFill).disabled(!model.canUseBoard).help("运行编辑区，不写入设备文件 · ⌘R")
                }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 9).fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text("上传路径").font(.system(size: 10)).foregroundStyle(.secondary)
                    TextField("/data/Script/demo.py", text: $model.remoteDestination)
                        .textFieldStyle(.plain).font(.system(size: 11, design: .monospaced)).accessibilityLabel("上传路径")
                }.padding(.horizontal, 13).padding(.bottom, 10)
                Divider()
                CodeEditor(text: Binding(get: { model.activeDocument?.text ?? "" }, set: { model.updateText($0) }),
                           fontSize: model.fontSize, documentID: document.id)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                HStack {
                    Text(document.localURL?.path ?? document.remotePath ?? "未保存的本机草稿").lineLimit(1).truncationMode(.middle)
                    Spacer()
                    Text("\(document.text.components(separatedBy: "\n").count) 行 · \(encodingLabel(document)) · Python")
                }.font(.system(size: 10)).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.vertical, 6)
            } else {
                VStack(spacing: 14) {
                    Text("打开或新建一个 Python 文件").foregroundStyle(.secondary)
                    Button("新建文件") { model.newDocument() }
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func encodingLabel(_ document: EditorDocument) -> String {
        guard let source = document.importedEncoding, source != "UTF-8" else { return "UTF-8" }
        return source + " → UTF-8"
    }

    private var console: some View {
        VStack(spacing: 0) {
            HStack(spacing: 9) {
                Label("MicroPython 终端", systemImage: "terminal").font(.system(size: 12, weight: .medium))
                if model.boardRunning { ProgressView().controlSize(.mini); Text("运行中").font(.caption).foregroundStyle(accent) }
                Spacer()
                Button("清空") { model.clearConsole() }
                Button { model.stopBoard() } label: { Label("停止", systemImage: "stop.fill") }
                    .disabled(!model.boardRunning && !model.boardBusy).help("发送 Ctrl-C · ⌘.")
            }.controlSize(.small).padding(.horizontal, 13).padding(.vertical, 8)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 0) {
                        Text(model.console.isEmpty ? "设备输出会显示在这里。可在下方执行 Python 语句。" : model.console)
                            .font(.system(size: model.fontSize - 1, design: .monospaced))
                            .foregroundStyle(model.console.isEmpty ? Color.secondary : .primary)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        Color.clear.frame(height: 1).id("consoleEnd")
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(12)
                }.background(Color(nsColor: .textBackgroundColor))
                    .onChange(of: model.console) { _ in proxy.scrollTo("consoleEnd", anchor: .bottomLeading) }
            }
            Divider()
            HStack(spacing: 9) {
                Text(model.boardRunning ? "stdin" : ">>>").foregroundStyle(accent).font(.system(size: 13, weight: .medium, design: .monospaced))
                TextField(model.boardRunning ? "仅在脚本等待 input() 时发送一行输入" : "输入 Python 语句，回车执行", text: $model.commandLine)
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .accessibilityLabel("Python 终端输入").onSubmit { model.executeCommand() }
                    .disabled(!model.boardConnected || model.boardBusy)
                Menu {
                    ForEach(Array(model.commandHistory.enumerated()).reversed(), id: \.offset) { item in
                        Button(String(item.element.prefix(80))) { model.commandLine = item.element }
                    }
                } label: { Image(systemName: "clock.arrow.circlepath") }.frame(width: 35).help("命令历史")
                Button { model.executeCommand() } label: { Image(systemName: "return") }.buttonStyle(.borderless).disabled(!model.boardConnected || model.boardBusy)
            }.padding(.horizontal, 13).padding(.vertical, 10)
        }
    }
}
