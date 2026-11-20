import Foundation

/// 扫描到的设备。
struct ScannedDevice: Identifiable, Hashable {
    var id: String { host }
    var host: String
    var model: String
}

/// 扫描局域网里的 ADB 设备（5555 端口）。
/// 先用 POSIX socket 快速探测端口，再对通的主机做一次 ADB 握手读型号。
enum DeviceScanner {
    /// 本机 WiFi（en0）的 IPv4 地址，没有 WiFi 时返回 nil。
    static func localWiFiIP() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let current = ptr {
            let flags = current.pointee.ifa_flags
            let isUp = (flags & UInt32(IFF_UP)) != 0
            let isLoopback = (flags & UInt32(IFF_LOOPBACK)) != 0
            if isUp, !isLoopback,
               let addr = current.pointee.ifa_addr,
               addr.pointee.sa_family == sa_family_t(AF_INET),
               String(cString: current.pointee.ifa_name) == "en0" {
                var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                getnameinfo(addr, socklen_t(addr.pointee.sa_len),
                            &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
                return String(cString: host)
            }
            ptr = current.pointee.ifa_next
        }
        return nil
    }

    /// 扫描本机所在的 /24 网段，返回监听 5555 端口的主机。
    /// 握手读不到型号的（比如还没在电视上点允许），型号显示为“Android TV”。
    static func scan() async -> [ScannedDevice] {
        guard let localIP = localWiFiIP() else { return [] }
        let parts = localIP.split(separator: ".")
        guard parts.count == 4 else { return [] }
        let prefix = parts[0..<3].joined(separator: ".")

        // 第一阶段：端口探测（阻塞式 socket，并发 32）。
        let openHosts = await probePorts(prefix: prefix)

        // 第二阶段：ADB 握手读型号（每台最多等 6 秒）。
        var found: [ScannedDevice] = []
        await withTaskGroup(of: ScannedDevice.self) { group in
            for host in openHosts {
                group.addTask {
                    let conn = ADBConnection(host: host)
                    do {
                        try await conn.connect(handshakeTimeout: 6)
                        let model = conn.deviceModel ?? "Android TV"
                        conn.disconnect()
                        return ScannedDevice(host: host, model: model)
                    } catch {
                        conn.disconnect()
                        return ScannedDevice(host: host, model: "Android TV")
                    }
                }
            }
            for await device in group {
                found.append(device)
            }
        }
        return found.sorted { $0.host < $1.host }
    }

    /// 并发探测 1...254 的 5555 端口，返回通的主机。
    private static func probePorts(prefix: String) async -> [String] {
        // 用 class 包装结果，避免可变变量被并发闭包捕获。
        final class Box: @unchecked Sendable {
            var hosts: [String] = []
            let lock = NSLock()
            func append(_ host: String) {
                lock.lock(); hosts.append(host); lock.unlock()
            }
        }
        let box = Box()
        return await withCheckedContinuation { (cont: CheckedContinuation<[String], Never>) in
            let group = DispatchGroup()
            let semaphore = DispatchSemaphore(value: 32)
            for i in 1...254 {
                let host = "\(prefix).\(i)"
                semaphore.wait()
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    defer {
                        semaphore.signal()
                        group.leave()
                    }
                    if isPortOpen(host: host, port: 5555, timeout: 1.0) {
                        box.append(host)
                    }
                }
            }
            group.notify(queue: .global(qos: .userInitiated)) {
                cont.resume(returning: box.hosts)
            }
        }
    }

    /// 非阻塞 connect + poll，1 秒超时判断端口是否通。
    private static func isPortOpen(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        var flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0 else { return false }
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(port).bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let result = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        guard ready > 0, (pfd.revents & Int16(POLLOUT)) != 0 else { return false }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }
}
