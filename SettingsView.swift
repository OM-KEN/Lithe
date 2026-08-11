import AppKit
import SwiftUI

struct LitheSettingsView: View {
    @AppStorage(LitheDefaults.autoCopyResults) private var autoCopyResults = true
    @AppStorage(LitheDefaults.autoTrashOriginals) private var autoTrashOriginals = false
    @AppStorage(LitheDefaults.autoTrashConfirmationSeen) private var confirmationSeen = false
    @AppStorage(LitheDefaults.autoCloseInterval) private var autoCloseInterval = 10.0
    @AppStorage(LitheDefaults.fixedOutputDirectory) private var fixedOutputDirectory = ""
    @State private var showingTrashConfirmation = false

    var body: some View {
        Form {
            Section("完成后") {
                Toggle("把压缩结果复制到剪贴板", isOn: $autoCopyResults)
                Toggle("把原图移到废纸篓", isOn: Binding(
                    get: { autoTrashOriginals },
                    set: { value in
                        if value, !confirmationSeen {
                            showingTrashConfirmation = true
                        } else {
                            autoTrashOriginals = value
                        }
                    }
                ))
                Picker("结果窗口自动关闭", selection: $autoCloseInterval) {
                    Text("10 秒").tag(10.0)
                    Text("30 秒").tag(30.0)
                    Text("永不").tag(0.0)
                }
            }

            Section("输出位置") {
                HStack {
                    Text(fixedOutputDirectory.isEmpty ? "与原图相同" : fixedOutputDirectory)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Button("选择…") { chooseOutputDirectory() }
                    if !fixedOutputDirectory.isEmpty {
                        Button("重置") { fixedOutputDirectory = "" }
                    }
                }
            }

            Section("关于") {
                HStack {
                    Text("Lithe")
                    Spacer()
                    Text(Bundle.main.object(
                        forInfoDictionaryKey: "CFBundleShortVersionString"
                    ) as? String ?? "0.1.0")
                        .foregroundStyle(.secondary)
                }
                Text("GPL-3.0-or-later · 本软件不提供任何担保")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Button("查看许可证") { openResource(name: "LICENSE", fileExtension: nil) }
                    Button("第三方声明") {
                        openResource(name: "THIRD_PARTY_NOTICES", fileExtension: "md")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 460)
        .padding(.vertical, 12)
        .alert("自动移到废纸篓", isPresented: $showingTrashConfirmation) {
            Button("取消", role: .cancel) { autoTrashOriginals = false }
            Button("开启") {
                confirmationSeen = true
                autoTrashOriginals = true
            }
        } message: {
            Text("压缩成功后，原图会移到系统废纸篓。你可以在结果窗口当前会话内撤销。")
        }
    }

    private func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            fixedOutputDirectory = url.path
        }
    }

    private func openResource(name: String, fileExtension: String?) {
        guard let url = Bundle.main.url(forResource: name, withExtension: fileExtension) else { return }
        NSWorkspace.shared.open(url)
    }
}
