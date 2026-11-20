import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// 设备详情：连接状态、装 APK、应用列表、打开/卸载、重启、截图。
struct DeviceDetailView: View {
    let device: TVDevice

    @EnvironmentObject private var store: DeviceStore

    @State private var connection: ADBConnection?
    @State private var statusText = "正在连接…"
    @State private var isConnected = false
    @State private var isConnecting = true
    @State private var errorMessage: String?

    @State private var apps: [InstalledApp] = []
    @State private var isLoadingApps = false

    @State private var showingFileImporter = false
    @State private var installProgress = ""
    @State private var isInstalling = false
    @State private var installResult = ""
    @State private var showingInstallResult = false

    @State private var appToUninstall: InstalledApp?
    @State private var showingUninstallConfirm = false
    @State private var isSavingScreenshot = false
    @State private var notice = ""
    @State private var showingNotice = false

    var body: some View {
        List {
            // 状态
            Section {
                HStack {
                    Text("状态")
                    Spacer()
                    if isConnecting {
                        ProgressView()
                    } else {
                        Text(isConnected ? "已连接" : "未连接")
                            .fontWeight(.semibold)
                            .foregroundColor(isConnected ? .green : .red)
                    }
                }
                HStack {
                    Text("设备")
                    Spacer()
                    Text(device.name)
                        .foregroundColor(.secondary)
                }
                HStack {
                    Text("IP 地址")
                    Spacer()
                    Text(device.host)
                        .foregroundColor(.secondary)
                }
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.subheadline)
                } else {
                    Text(statusText)
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                }
            }

            // 操作
            Section("操作") {
                Button(action: { showingFileImporter = true }) {
                    Label("安装 APK", systemImage: "square.and.arrow.down")
                }
                .disabled(!isConnected || isInstalling)

                if isInstalling {
                    HStack {
                        ProgressView()
                        Text(installProgress.isEmpty ? "正在处理…" : installProgress)
                            .foregroundColor(.secondary)
                    }
                }

                Button(action: takeScreenshot) {
                    Label("电视截图", systemImage: "camera")
                }
                .disabled(!isConnected || isSavingScreenshot)

                Button(action: rebootBox) {
                    Label("重启盒子", systemImage: "arrow.clockwise")
                }
                .disabled(!isConnected)

                Button(action: refreshAppsAction) {
                    Label("刷新应用列表", systemImage: "arrow.triangle.2.circlepath")
                }
                .disabled(!isConnected || isLoadingApps)
            }

            // 已装应用
            Section("已装应用（第三方）") {
                if isLoadingApps {
                    HStack {
                        ProgressView()
                        Text("正在读取…")
                            .foregroundColor(.secondary)
                    }
                } else if apps.isEmpty {
                    Text("没有找到第三方应用。")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(apps) { app in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(app.displayName)
                                    .font(.subheadline)
                                    .lineLimit(2)
                            }
                            Spacer()
                            Button("打开") { launchApp(app) }
                                .buttonStyle(.bordered)
                                .controlSize(.small)
                            Button("卸载") {
                                appToUninstall = app
                                showingUninstallConfirm = true
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .tint(.red)
                        }
                    }
                }
            }

            Section {
                Text("第一次连接时，电视上会弹出“允许 USB 调试吗？”的窗口，请在电视上点“允许”。之后再连就不用点了。")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            }
        }
        .navigationTitle(device.name)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                if isConnected {
                    Button("断开") { disconnect() }
                } else if !isConnecting {
                    Button("重连") { connect() }
                }
            }
        }
        .fileImporter(
            isPresented: $showingFileImporter,
            allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    installAPK(from: url)
                }
            case .failure(let error):
                showNotice("选择文件失败：\(error.localizedDescription)")
            }
        }
        .alert("安装结果", isPresented: $showingInstallResult) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(installResult)
        }
        .alert("卸载应用？", isPresented: $showingUninstallConfirm) {
            Button("取消", role: .cancel) {}
            Button("卸载", role: .destructive) {
                if let app = appToUninstall {
                    uninstallApp(app)
                }
            }
        } message: {
            Text("确定要从盒子上卸载 \(appToUninstall?.displayName ?? "") 吗？")
        }
        .alert("提示", isPresented: $showingNotice) {
            Button("知道了", role: .cancel) {}
        } message: {
            Text(notice)
        }
        .onAppear {
            connect()
        }
        .onDisappear {
            disconnect()
        }
    }

    // MARK: - 连接

    private func connect() {
        isConnecting = true
        isConnected = false
        errorMessage = nil
        statusText = "正在连接…"
        let conn = ADBConnection(host: device.host)
        connection = conn
        Task {
            do {
                try await conn.connect()
                await MainActor.run {
                    isConnected = true
                    isConnecting = false
                    statusText = "已连接到 \(conn.deviceName)"
                    store.markConnected(device)
                }
                await refreshApps()
            } catch {
                await MainActor.run {
                    isConnected = false
                    isConnecting = false
                    errorMessage = error.localizedDescription
                }
            }
        }
    }

    private func disconnect() {
        connection?.disconnect()
        connection = nil
        isConnected = false
        isConnecting = false
    }

    // MARK: - 应用列表

    private func refreshApps() async {
        guard let conn = connection, isConnected else { return }
        await MainActor.run { isLoadingApps = true }
        do {
            let packages = try await conn.listApps()
            await MainActor.run {
                apps = packages.map { InstalledApp(packageName: $0, label: nil) }
                isLoadingApps = false
            }
        } catch {
            await MainActor.run {
                isLoadingApps = false
                errorMessage = error.localizedDescription
            }
        }
    }

    private func refreshAppsAction() {
        Task { await refreshApps() }
    }

    private func launchApp(_ app: InstalledApp) {
        guard let conn = connection else { return }
        Task {
            do {
                try await conn.launch(package: app.packageName)
                await MainActor.run { showNotice("已在电视上打开 \(app.displayName)") }
            } catch {
                await MainActor.run { showNotice("打开失败：\(error.localizedDescription)") }
            }
        }
    }

    private func uninstallApp(_ app: InstalledApp) {
        guard let conn = connection else { return }
        Task {
            do {
                let out = try await conn.uninstall(package: app.packageName)
                await MainActor.run {
                    if out.contains("Success") {
                        apps.removeAll { $0.packageName == app.packageName }
                        showNotice("已卸载 \(app.displayName)")
                    } else {
                        showNotice("卸载失败：\(out)")
                    }
                }
            } catch {
                await MainActor.run { showNotice("卸载失败：\(error.localizedDescription)") }
            }
        }
    }

    // MARK: - 安装 APK

    private func installAPK(from url: URL) {
        guard let conn = connection else { return }
        isInstalling = true
        installProgress = "正在准备文件…"
        Task {
            // 文件选择器给的是沙盒外 URL，先复制到临时目录再传。
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent(url.lastPathComponent)
            do {
                let accessing = url.startAccessingSecurityScopedResource()
                defer { if accessing { url.stopAccessingSecurityScopedResource() } }
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    try FileManager.default.removeItem(at: tempURL)
                }
                try FileManager.default.copyItem(at: url, to: tempURL)
            } catch {
                await MainActor.run {
                    isInstalling = false
                    installResult = "读取文件失败：\(error.localizedDescription)"
                    showingInstallResult = true
                }
                return
            }

            await MainActor.run { installProgress = "正在上传到盒子…" }
            do {
                let out = try await conn.install(apkURL: tempURL)
                await MainActor.run {
                    isInstalling = false
                    installResult = "安装成功 ✅\n\(out)"
                    showingInstallResult = true
                }
                try? FileManager.default.removeItem(at: tempURL)
                await refreshApps()
            } catch {
                await MainActor.run {
                    isInstalling = false
                    installResult = "安装失败 ❌\n\(error.localizedDescription)"
                    showingInstallResult = true
                }
                try? FileManager.default.removeItem(at: tempURL)
            }
        }
    }

    // MARK: - 截图与重启

    private func takeScreenshot() {
        guard let conn = connection else { return }
        isSavingScreenshot = true
        Task {
            do {
                let png = try await conn.screenshot()
                await MainActor.run {
                    if let image = UIImage(data: png) {
                        UIImageWriteToSavedPhotosAlbum(image, nil, nil, nil)
                        showNotice("截图已保存到相册")
                    } else {
                        showNotice("截图失败：图片数据不对")
                    }
                    isSavingScreenshot = false
                }
            } catch {
                await MainActor.run {
                    isSavingScreenshot = false
                    showNotice("截图失败：\(error.localizedDescription)")
                }
            }
        }
    }

    private func rebootBox() {
        guard let conn = connection else { return }
        Task {
            do {
                try await conn.reboot()
                await MainActor.run { showNotice("盒子正在重启") }
            } catch {
                await MainActor.run { showNotice("重启失败：\(error.localizedDescription)") }
            }
        }
    }

    private func showNotice(_ text: String) {
        notice = text
        showingNotice = true
    }
}
