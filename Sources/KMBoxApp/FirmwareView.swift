import SwiftUI
import KMBoxCore

struct FirmwareView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        Picker("设备型号", selection: $model.deviceModel) {
                            ForEach(DeviceModel.allCases) { Text($0.rawValue).tag($0) }
                        }.disabled(!model.canChangeModel)
                        Text(model.deviceModel.compatibility)
                        Text("以上为官方文档与协议支持范围；所有型号的实机验收仍待完成。型号由你选择，程序不会通过握手自动认定型号。")
                            .font(.caption).foregroundStyle(.secondary)
                        Text(model.deviceModel.firmwareNote).font(.callout)
                        Link("打开该型号的官方固件页面", destination: model.deviceModel.firmwareURL)
                    }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                }
                if model.deviceModel.supportsFirmwareHosting {
                    GroupBox("NB 固件更新 · 官方 Web 下载方式") {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("1. 选择官网下载的 NB .cpio 固件包")
                            HStack {
                                Button("选择 NB 固件…") { model.chooseFirmware() }.disabled(model.firmwareActive)
                                Text(model.firmwareName.isEmpty ? "尚未选择" : model.firmwareName).foregroundStyle(.secondary)
                            }
                            if let firmware = model.firmware {
                                Text("格式检查通过 · \(firmware.data.count) 字节").font(.callout)
                                Text("SHA-256  " + firmware.sha256).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                                Text("格式检查和 SHA-256 指纹不等于厂商数字签名验证；只使用对应型号的官方文件。")
                                    .font(.caption).foregroundStyle(.secondary)
                                ForEach(firmware.warnings, id: \.self) { Text($0).font(.caption).foregroundStyle(.orange) }
                            }
                            Divider()
                            Text("2. 选择连接 NB 的 Mac 网卡地址")
                            HStack {
                                Picker("Mac 地址", selection: $model.firmwareAddress) {
                                    Text("请选择网卡 IPv4").tag("")
                                    ForEach(model.interfaces) { Text("\($0.name) · \($0.address)").tag($0.address) }
                                }
                                Button("刷新") { model.refreshInterfaces() }
                            }.disabled(model.firmwareActive)
                            TextField("来源 IP 限制（可选，留空即可）", text: $model.firmwareDeviceAddress).textFieldStyle(.roundedBorder)
                                .disabled(model.firmwareActive)
                            Text("服务限定所选网卡的 TCP 80 端口，仅提供 /kmboxNB.cpio。需要只让一台盒子下载时，可填写来源 IP；通常无需填写。原文件无需重命名。")
                                .font(.caption).foregroundStyle(.secondary)
                            HStack {
                                Button("启动固件服务") { model.startFirmwareServer() }
                                    .disabled(model.firmware == nil || model.firmwareAddress.isEmpty || !model.canChangeModel)
                                Button("停止服务") { model.stopFirmwareServer() }.disabled(!model.firmwareActive)
                            }
                            Text("3. 在 NB 的升级页面填入上方 Mac 地址，由你点击盒子上的升级按钮")
                            Text("先断开本程序的 Net / B 串口连接，备份板载脚本与配置；升级时保持供电和网络，勿退出程序。此功能用于正常固件更新，不能救援无法启动到升级页的设备。")
                                .font(.callout)
                            if let status = model.firmwareStatus {
                                Text(status.message).textSelection(.enabled)
                                if let firmware = model.firmware {
                                    ProgressView(value: Double(status.bytesSent), total: Double(firmware.data.count))
                                }
                                Text("已完成文件发送：\(status.completedDownloads) 次。仍需在盒子重启后核对版本，才能确认刷写成功。")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            if !model.firmwareError.isEmpty { Text(model.firmwareError).foregroundStyle(.red).textSelection(.enabled) }
                            Link("官方 NB 升级教程", destination: URL(string: "https://www.kmbox.top/wiki_doc/kmboxNB/site/03-update/")!)
                        }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }.padding(25).frame(maxWidth: 960)
        }
    }
}
