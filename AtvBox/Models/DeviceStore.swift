import Foundation

/// 一台电视盒子（或安卓电视）。
struct TVDevice: Identifiable, Codable, Equatable {
    var id: String { host }
    var host: String
    var name: String
    var lastConnected: Date?

    init(host: String, name: String, lastConnected: Date? = nil) {
        self.host = host
        self.name = name
        self.lastConnected = lastConnected
    }
}

/// 盒子里装的一个应用。
struct InstalledApp: Identifiable {
    var id: String { packageName }
    var packageName: String
    var label: String?

    var displayName: String { label ?? packageName }
}

/// 已保存的设备，存在 UserDefaults 里。
final class DeviceStore: ObservableObject {
    @Published private(set) var devices: [TVDevice] = []
    @Published private(set) var lastConnectedHost: String?

    private let devicesKey = "com.atvbox.savedDevices"
    private let lastHostKey = "com.atvbox.lastConnectedHost"

    init() {
        load()
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: devicesKey),
           let saved = try? JSONDecoder().decode([TVDevice].self, from: data) {
            devices = saved
        }
        lastConnectedHost = UserDefaults.standard.string(forKey: lastHostKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: devicesKey)
        }
        UserDefaults.standard.set(lastConnectedHost, forKey: lastHostKey)
    }

    /// 上次连上的设备（没有则返回 nil）。
    var lastConnectedDevice: TVDevice? {
        guard let host = lastConnectedHost else { return nil }
        return devices.first { $0.host == host }
    }

    /// 保存或更新一台设备（按 IP 去重）。
    func saveDevice(_ device: TVDevice) {
        if let index = devices.firstIndex(where: { $0.host == device.host }) {
            devices[index].name = device.name
        } else {
            devices.append(device)
        }
        persist()
    }

    func removeDevice(_ device: TVDevice) {
        devices.removeAll { $0.host == device.host }
        if lastConnectedHost == device.host {
            lastConnectedHost = nil
        }
        persist()
    }

    func removeAllDevices() {
        devices.removeAll()
        lastConnectedHost = nil
        persist()
    }

    /// 记下这次连上的设备，并更新“最后一次连接”。
    func markConnected(_ device: TVDevice) {
        var updated = device
        updated.lastConnected = Date()
        if let index = devices.firstIndex(where: { $0.host == device.host }) {
            devices[index] = updated
        } else {
            devices.append(updated)
        }
        lastConnectedHost = device.host
        persist()
    }
}
