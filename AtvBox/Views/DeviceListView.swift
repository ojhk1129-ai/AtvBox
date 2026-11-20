import SwiftUI

/// 设备列表，照着 atvTools 的样子：
/// “最后一次连接”卡片 + “设备”区（全部 / 已保存）+ 扫描 + 右下角“更多”。
struct DeviceListView: View {
    @EnvironmentObject private var store: DeviceStore

    @State private var scanned: [ScannedDevice] = []
    @State private var isScanning = false
    @State private var segment = 0 // 0 全部，1 已保存
    @State private var didInitialScan = false

    @State private var showingAddIP = false
    @State private var manualIP = ""
    @State private var showingAbout = false
    @State private var showingClearConfirm = false

    /// 全部：扫描到的和已保存的合并，已保存的名字优先。
    private var allDevices: [TVDevice] {
        var merged: [String: TVDevice] = [:]
        for s in scanned {
            merged[s.host] = TVDevice(host: s.host, name: s.model)
        }
        for d in store.devices {
            merged[d.host] = d
        }
        return merged.values.sorted { $0.host < $1.host }
    }

    private var shownDevices: [TVDevice] {
        segment == 0 ? allDevices : store.devices.sorted { $0.host < $1.host }
    }

    var body: some View {
        NavigationView {
            ZStack(alignment: .bottomTrailing) {
                List {
                    // 最后一次连接
                    if let last = store.lastConnectedDevice {
                        Section("最后一次连接") {
                            NavigationLink(destination: DeviceDetailView(device: last)) {
                                DeviceRow(device: last)
                            }
                        }
                    }

                    // 设备
                    Section(header: deviceSectionHeader) {
                        if shownDevices.isEmpty {
                            if isScanning {
                                HStack {
                                    ProgressView()
                                    Text("正在搜索…")
                                        .foregroundColor(.secondary)
                                }
                            } else {
                                Text("没有找到设备\n请确认手机和盒子在同一个 WiFi 下，盒子已开启 ADB 调试。")
                                    .foregroundColor(.secondary)
                            }
                        } else {
                            ForEach(shownDevices) { device in
                                NavigationLink(destination: DeviceDetailView(device: device)) {
                                    DeviceRow(device: device)
                                }
                            }
                            .onDelete(perform: deleteSaved)
                        }

                        // 手动输入 IP
                        Button(action: { showingAddIP = true }) {
                            Label("手动输入 IP 连接", systemImage: "plus.circle")
                        }
                    }

                    Section {
                        Text("此处只能找到开启了 ADB 调试的安卓电视或电视盒子。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle("AtvBox")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Button(action: startScan) {
                            if isScanning {
                                ProgressView()
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .disabled(isScanning)
                    }
                }

                // 右下角“更多”
                Menu {
                    Button("关于 AtvBox", action: { showingAbout = true })
                    Button("清空已保存的设备", role: .destructive) {
                        showingClearConfirm = true
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis.circle")
                        .font(.title3)
                        .padding(12)
                }
                .padding()
            }
            .alert("手动输入 IP", isPresented: $showingAddIP) {
                TextField("例如 192.168.10.14", text: $manualIP)
                    .keyboardType(.decimalPad)
                Button("取消", role: .cancel) {}
                Button("连接") {
                    let ip = manualIP.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !ip.isEmpty else { return }
                    manualIP = ""
                    let device = TVDevice(host: ip, name: ip)
                    store.saveDevice(device)
                }
            } message: {
                Text("输入电视盒子的 IP 地址（在盒子 设置 → 网络 里查看）。")
            }
            .alert("关于 AtvBox", isPresented: $showingAbout) {
                Button("知道了", role: .cancel) {}
            } message: {
                Text("AtvBox 是一款免费开源的工具：手机通过 ADB（WiFi）连接安卓电视或电视盒子，安装 APK、管理应用、截图。\n\n使用前请在盒子上开启 ADB 调试，并确保手机和盒子在同一个 WiFi 下。")
            }
            .alert("清空已保存的设备？", isPresented: $showingClearConfirm) {
                Button("取消", role: .cancel) {}
                Button("清空", role: .destructive) {
                    store.removeAllDevices()
                    scanned.removeAll()
                }
            }
            .onAppear {
                if !didInitialScan {
                    didInitialScan = true
                    startScan()
                }
            }
        }
    }

    private var deviceSectionHeader: some View {
        HStack {
            Text("设备")
            Spacer()
            Picker("", selection: $segment) {
                Text("全部").tag(0)
                Text("已保存").tag(1)
            }
            .pickerStyle(.segmented)
            .frame(width: 160)
            if isScanning {
                ProgressView()
                    .padding(.leading, 4)
            }
        }
    }

    private func startScan() {
        guard !isScanning else { return }
        isScanning = true
        Task {
            let found = await DeviceScanner.scan()
            await MainActor.run {
                scanned = found
                isScanning = false
            }
        }
    }

    private func deleteSaved(at offsets: IndexSet) {
        for index in offsets {
            store.removeDevice(shownDevices[index])
        }
    }
}

/// 设备行：电视图标 + 名字 + IP + 右箭头（NavigationLink 自带）。
struct DeviceRow: View {
    let device: TVDevice

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "tv")
                .font(.title2)
                .foregroundColor(.accentColor)
                .frame(width: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.headline)
                Text(device.host)
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
            Spacer()
            if let last = device.lastConnected {
                Text(last, style: .relative)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}
