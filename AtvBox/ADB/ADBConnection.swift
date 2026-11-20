import Foundation
import Network

/// ADB 连接层错误，描述都是中文，直接显示给用户。
enum ADBError: Error, LocalizedError {
    case notConnected
    case connectionFailed(String)
    case authFailed
    case authTimeout
    case streamFailed(String)
    case timeout
    case installFailed(String)

    var errorDescription: String? {
        switch self {
        case .notConnected:
            return "未连接到设备"
        case .connectionFailed(let message):
            return "连接失败：\(message)"
        case .authFailed:
            return "授权失败，请在电视上允许 USB 调试授权"
        case .authTimeout:
            return "等待授权超时：请在电视上允许 USB 调试授权，然后重试"
        case .streamFailed(let message):
            return "操作失败：\(message)"
        case .timeout:
            return "操作超时"
        case .installFailed(let message):
            return "安装失败：\(message)"
        }
    }
}

/// 带超时的异步执行：超时后抛 ADBError.timeout。
func withTimeout<T>(seconds: TimeInterval, operation: @Sendable @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw ADBError.timeout
        }
        guard let result = try await group.next() else { throw ADBError.timeout }
        group.cancelAll()
        return result
    }
}

/// 一条 ADB 流（对应一个 OPEN 出去的通道，如 shell: 或 sync:）。
/// 数据按 maxData 切块发 WRTE，每块等对方 OKAY 回执再发下一块。
final class ADBStream: @unchecked Sendable {
    let localId: UInt32
    var remoteId: UInt32 = 0
    private weak var connection: ADBConnection?
    private let lock = NSLock()
    private var chunks: [Data] = []
    private var chunkWaiters: [CheckedContinuation<Data?, Error>] = []
    private var ackWaiters: [CheckedContinuation<Void, Error>] = []
    private var isClosed = false

    init(localId: UInt32, connection: ADBConnection) {
        self.localId = localId
        self.connection = connection
    }

    /// 发数据：按 maxData 切块，每块等 OKAY 回执。
    func write(_ data: Data) async throws {
        var offset = 0
        while offset < data.count {
            let n = min(Int(ADB.maxData), data.count - offset)
            let chunk = Data(data[offset..<(offset + n)])
            guard let conn = connection else { throw ADBError.notConnected }
            try await conn.sendMessage(ADBMessage(
                command: ADB.aWrte, arg0: localId, arg1: remoteId, data: chunk))
            try await waitAck()
            offset += n
        }
    }

    private func waitAck() async throws {
        lock.lock()
        if isClosed { lock.unlock(); throw ADBError.streamFailed("流已关闭") }
        lock.unlock()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            lock.lock()
            if isClosed {
                lock.unlock()
                cont.resume(throwing: ADBError.streamFailed("流已关闭"))
                return
            }
            ackWaiters.append(cont)
            lock.unlock()
        }
    }

    /// 对方确认收到一个 WRTE 块。
    func ackReceived() {
        lock.lock()
        guard !ackWaiters.isEmpty else { lock.unlock(); return }
        let cont = ackWaiters.removeFirst()
        lock.unlock()
        cont.resume()
    }

    /// 收到对方发来的一个数据块。
    func deliver(_ data: Data) {
        lock.lock()
        chunks.append(data)
        if let waiter = chunkWaiters.first {
            chunkWaiters.removeFirst()
            let chunk = chunks.removeFirst()
            lock.unlock()
            waiter.resume(returning: chunk)
            return
        }
        lock.unlock()
    }

    /// 取下一个数据块；流关闭且无剩余数据时返回 nil。
    func readChunk() async throws -> Data? {
        lock.lock()
        if !chunks.isEmpty {
            let chunk = chunks.removeFirst()
            lock.unlock()
            return chunk
        }
        if isClosed {
            lock.unlock()
            return nil
        }
        lock.unlock()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data?, Error>) in
            lock.lock()
            if !chunks.isEmpty {
                let chunk = chunks.removeFirst()
                lock.unlock()
                cont.resume(returning: chunk)
                return
            }
            if isClosed {
                lock.unlock()
                cont.resume(returning: nil)
                return
            }
            chunkWaiters.append(cont)
            lock.unlock()
        }
    }

    /// 读满 n 个字节（供 sync 协议按帧读取用）。
    func readExactly(_ count: Int) async throws -> Data {
        var out = Data()
        while out.count < count {
            guard let chunk = try await readChunk() else {
                throw ADBError.streamFailed("流已关闭")
            }
            let need = count - out.count
            if chunk.count <= need {
                out.append(chunk)
            } else {
                out.append(chunk.prefix(need))
                lock.lock()
                chunks.insert(Data(chunk.suffix(chunk.count - need)), at: 0)
                lock.unlock()
            }
        }
        return out
    }

    /// 对方发来 CLSE，或连接断开时调用。
    func closeStream() {
        lock.lock()
        guard !isClosed else { lock.unlock(); return }
        isClosed = true
        let cws = chunkWaiters; chunkWaiters.removeAll()
        let aws = ackWaiters; ackWaiters.removeAll()
        lock.unlock()
        for w in cws { w.resume(returning: nil) }
        for w in aws { w.resume(throwing: ADBError.streamFailed("流已关闭")) }
    }

    /// 主动关闭流：发 CLSE。
    func close() async {
        if let conn = connection {
            try? await conn.sendMessage(ADBMessage(
                command: ADB.aClse, arg0: localId, arg1: remoteId, data: Data()))
        }
        closeStream()
        connection?.removeStream(localId)
    }
}

/// ADB 客户端：TCP 连盒子 5555 端口，握手认证后可执行 shell、传文件、装应用。
final class ADBConnection: @unchecked Sendable {
    let host: String
    let port: UInt16 = 5555

    var deviceName: String { deviceModel ?? host }

    private let queue = DispatchQueue(label: "com.atvbox.adb")
    private let lock = NSLock()
    private var connection: NWConnection?
    private var nextLocalId: UInt32 = 1
    private var buffer = Data()
    private var closed = false
    private var readyContinuation: CheckedContinuation<Void, Error>?

    private struct ReadWaiter {
        let count: Int
        let continuation: CheckedContinuation<Data, Error>
    }
    private var readWaiters: [ReadWaiter] = []
    private var streams: [UInt32: ADBStream] = [:]
    private var pendingOpen: [UInt32: CheckedContinuation<UInt32, Error>] = [:]
    private var dispatchTask: Task<Void, Never>?

    private var _deviceModel: String?
    var deviceModel: String? {
        lock.lock(); defer { lock.unlock() }
        return _deviceModel
    }
    private var _isConnected = false
    var isConnected: Bool {
        lock.lock(); defer { lock.unlock() }
        return _isConnected
    }

    init(host: String) {
        self.host = host
    }

    // MARK: - 连接与握手

    /// 连接并完成握手。盒子没认过这把钥匙时，电视上会弹出授权框，
    /// 用户要在电视上点“允许”，握手整体最多等 handshakeTimeout 秒。
    func connect(handshakeTimeout: TimeInterval = 60) async throws {
        lock.lock()
        guard !closed else { lock.unlock(); throw ADBError.notConnected }
        lock.unlock()

        let nwConn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port)!,
            using: .tcp)
        connection = nwConn

        // 等 TCP 就绪（最多 10 秒）。
        try await withTimeout(seconds: 10) {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.lock.lock()
                self.readyContinuation = cont
                self.lock.unlock()
                nwConn.stateUpdateHandler = { [weak self] state in
                    guard let self = self else { return }
                    switch state {
                    case .ready:
                        self.resolveReady(.success(()))
                    case .failed(let error):
                        self.resolveReady(.failure(ADBError.connectionFailed(error.localizedDescription)))
                    case .cancelled:
                        self.resolveReady(.failure(ADBError.connectionFailed("连接已取消")))
                    default:
                        break
                    }
                }
                nwConn.start(queue: self.queue)
            }
        }

        startPump()

        do {
            try await withTimeout(seconds: handshakeTimeout) {
                try await self.performHandshake()
            }
        } catch {
            disconnect()
            if case ADBError.timeout = error { throw ADBError.authTimeout }
            throw error
        }

        lock.lock()
        _isConnected = true
        lock.unlock()

        dispatchTask = Task { [weak self] in
            guard let self = self else { return }
            await self.dispatchLoop()
        }
    }

    private func resolveReady(_ result: Result<Void, Error>) {
        lock.lock()
        guard let cont = readyContinuation else { lock.unlock(); return }
        readyContinuation = nil
        lock.unlock()
        switch result {
        case .success: cont.resume()
        case .failure(let error): cont.resume(throwing: error)
        }
    }

    /// 握手：发 CNXN，等对方 CNXN（可能先经过 AUTH 挑战）。
    private func performHandshake() async throws {
        try await sendMessage(ADBMessage(
            command: ADB.aCnxn, arg0: ADB.version, arg1: ADB.maxData,
            data: "host::".adbCString))
        var sentSignature = false
        var sentPublicKey = false
        while true {
            let msg = try await readMessage()
            switch msg.command {
            case ADB.aCnxn:
                parseBanner(msg.data)
                return
            case ADB.aAuth where msg.arg0 == ADB.authToken:
                let token = msg.data
                if !sentSignature {
                    sentSignature = true
                    let sig = try ADBKeyManager.shared.sign(token: token)
                    try await sendMessage(ADBMessage(
                        command: ADB.aAuth, arg0: ADB.authSignature, arg1: 0, data: sig))
                } else if !sentPublicKey {
                    sentPublicKey = true
                    let pub = try ADBKeyManager.shared.publicKeyString()
                    try await sendMessage(ADBMessage(
                        command: ADB.aAuth, arg0: ADB.authRSAPublicKey, arg1: 0,
                        data: pub.adbCString))
                }
                // 已经发过公钥还在要 token：说明在等电视上点允许，继续等，外层超时兜底。
            default:
                continue
            }
        }
    }

    /// CNXN 的 banner 形如 device::ro.product.name=X;ro.product.model=MagicBox_M17;…
    private func parseBanner(_ data: Data) {
        guard let banner = String(data: data, encoding: .utf8) else { return }
        for part in banner.split(separator: ";") {
            if part.hasPrefix("ro.product.model=") {
                let model = String(part.dropFirst("ro.product.model=".count))
                lock.lock()
                _deviceModel = model
                lock.unlock()
                return
            }
        }
    }

    /// 断开连接，清理所有等待中的读写和流。
    func disconnect() {
        dispatchTask?.cancel()
        dispatchTask = nil
        connection?.cancel()
        connectionClosed(error: ADBError.connectionFailed("连接已关闭"))
    }

    // MARK: - 底层收发

    private func startPump() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self = self else { return }
            if let data = data, !data.isEmpty {
                self.pumpDidReceive(data)
            }
            if let error = error {
                self.connectionClosed(error: ADBError.connectionFailed(error.localizedDescription))
                return
            }
            if isComplete {
                self.connectionClosed(error: ADBError.connectionFailed("连接已关闭"))
                return
            }
            self.startPump()
        }
    }

    private func pumpDidReceive(_ data: Data) {
        lock.lock()
        buffer.append(data)
        while let first = readWaiters.first, buffer.count >= first.count {
            readWaiters.removeFirst()
            let out = Data(buffer.prefix(first.count))
            buffer.removeFirst(first.count)
            lock.unlock()
            first.continuation.resume(returning: out)
            lock.lock()
        }
        lock.unlock()
    }

    private var cleanupDone = false

    private func connectionClosed(error: Error) {
        lock.lock()
        guard !cleanupDone else { lock.unlock(); return }
        cleanupDone = true
        closed = true
        _isConnected = false
        let waiters = readWaiters; readWaiters.removeAll()
        let opens = pendingOpen; pendingOpen.removeAll()
        let allStreams = streams; streams.removeAll()
        lock.unlock()
        for w in waiters { w.continuation.resume(throwing: error) }
        for (_, cont) in opens { cont.resume(throwing: error) }
        for (_, stream) in allStreams { stream.closeStream() }
    }

    private func readExactly(_ count: Int) async throws -> Data {
        lock.lock()
        if buffer.count >= count {
            let out = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            lock.unlock()
            return out
        }
        if closed {
            lock.unlock()
            throw ADBError.connectionFailed("连接已关闭")
        }
        lock.unlock()
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            lock.lock()
            if buffer.count >= count {
                let out = Data(buffer.prefix(count))
                buffer.removeFirst(count)
                lock.unlock()
                cont.resume(returning: out)
                return
            }
            if closed {
                lock.unlock()
                cont.resume(throwing: ADBError.connectionFailed("连接已关闭"))
                return
            }
            readWaiters.append(ReadWaiter(count: count, continuation: cont))
            lock.unlock()
        }
    }

    private func readMessage() async throws -> ADBMessage {
        let header = try await readExactly(24)
        let command = header.uint32LE(at: 0)
        let arg0 = header.uint32LE(at: 4)
        let arg1 = header.uint32LE(at: 8)
        let length = header.uint32LE(at: 12)
        let checksum = header.uint32LE(at: 16)
        let magic = header.uint32LE(at: 20)
        guard magic == (command ^ 0xffffffff) else {
            throw ADBError.streamFailed("消息校验失败")
        }
        guard length <= 16 * 1024 * 1024 else {
            throw ADBError.streamFailed("消息过大")
        }
        let payload = length > 0 ? try await readExactly(Int(length)) : Data()
        var sum: UInt32 = 0
        for b in payload { sum &+= UInt32(b) }
        guard sum == checksum else {
            throw ADBError.streamFailed("数据校验失败")
        }
        return ADBMessage(command: command, arg0: arg0, arg1: arg1, data: payload)
    }

    func sendMessage(_ message: ADBMessage) async throws {
        guard let conn = connection else { throw ADBError.notConnected }
        let data = message.encoded()
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { error in
                if let error = error {
                    cont.resume(throwing: ADBError.connectionFailed(error.localizedDescription))
                } else {
                    cont.resume()
                }
            })
        }
    }

    // MARK: - 消息分发

    private func dispatchLoop() async {
        while true {
            do {
                let msg = try await readMessage()
                dispatch(msg)
            } catch {
                connectionClosed(error: error)
                return
            }
        }
    }

    private func dispatch(_ msg: ADBMessage) {
        switch msg.command {
        case ADB.aOkay:
            // 先看是不是 OPEN 的回执，再看是不是 WRTE 的回执。
            lock.lock()
            if let cont = pendingOpen.removeValue(forKey: msg.arg1) {
                lock.unlock()
                cont.resume(returning: msg.arg0)
                return
            }
            let stream = streams[msg.arg1]
            lock.unlock()
            stream?.ackReceived()
        case ADB.aWrte:
            lock.lock()
            let stream = streams[msg.arg1]
            lock.unlock()
            stream?.deliver(msg.data)
        case ADB.aClse:
            lock.lock()
            if let cont = pendingOpen.removeValue(forKey: msg.arg1) {
                lock.unlock()
                cont.resume(throwing: ADBError.streamFailed("设备拒绝打开通道"))
                return
            }
            let stream = streams.removeValue(forKey: msg.arg1)
            lock.unlock()
            stream?.closeStream()
        default:
            break
        }
    }

    func removeStream(_ localId: UInt32) {
        lock.lock()
        streams.removeValue(forKey: localId)
        lock.unlock()
    }

    // MARK: - 流

    func open(_ destination: String) async throws -> ADBStream {
        lock.lock()
        guard !closed, connection != nil else {
            lock.unlock()
            throw ADBError.notConnected
        }
        let localId = nextLocalId
        nextLocalId &+= 1
        lock.unlock()

        let stream = ADBStream(localId: localId, connection: self)
        lock.lock()
        streams[localId] = stream
        lock.unlock()

        do {
            let remoteId: UInt32 = try await withTimeout(seconds: 15) {
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<UInt32, Error>) in
                    self.lock.lock()
                    self.pendingOpen[localId] = cont
                    self.lock.unlock()
                    Task {
                        do {
                            try await self.sendMessage(ADBMessage(
                                command: ADB.aOpen, arg0: localId, arg1: 0,
                                data: destination.adbCString))
                        } catch {
                            self.lock.lock()
                            if let c = self.pendingOpen.removeValue(forKey: localId) {
                                self.lock.unlock()
                                c.resume(throwing: error)
                            } else {
                                self.lock.unlock()
                            }
                        }
                    }
                }
            }
            stream.remoteId = remoteId
            return stream
        } catch {
            lock.lock()
            streams.removeValue(forKey: localId)
            lock.unlock()
            throw error
        }
    }

    // MARK: - 高层操作

    /// 在盒子上执行一条 shell 命令，返回全部输出。
    func shell(_ command: String) async throws -> String {
        let stream = try await open("shell:\(command)")
        var out = Data()
        while let chunk = try await stream.readChunk() {
            out.append(chunk)
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// 列出盒子里第三方安装的应用包名。
    func listApps() async throws -> [String] {
        let out = try await shell("pm list packages -3")
        return out.split(separator: "\n").compactMap { line -> String? in
            let s = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard s.hasPrefix("package:") else { return nil }
            return String(s.dropFirst("package:".count))
        }
    }

    /// 安装 APK：先传到盒子 /data/local/tmp/，再 pm install。
    func install(apkURL: URL) async throws -> String {
        let fileName = apkURL.lastPathComponent
        let remotePath = "/data/local/tmp/\(fileName)"
        try await push(localURL: apkURL, remotePath: remotePath)
        let out = try await shell("pm install -r \(remotePath)")
        _ = try? await shell("rm \(remotePath)")
        guard out.contains("Success") else {
            throw ADBError.installFailed(out.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return out
    }

    /// 卸载应用。
    func uninstall(package: String) async throws -> String {
        try await shell("pm uninstall \(package)")
    }

    /// 在电视上打开应用。
    func launch(package: String) async throws {
        _ = try await shell("monkey -p \(package) -c android.intent.category.LAUNCHER 1")
    }

    /// 重启盒子。
    func reboot() async throws {
        _ = try await shell("reboot")
    }

    /// 电视截图，返回 PNG 数据。
    func screenshot() async throws -> Data {
        let out = try await shell("screencap -p | base64")
        let cleaned = out.filter { !$0.isWhitespace }
        guard let data = Data(base64Encoded: cleaned, options: .ignoreUnknownCharacters),
              !data.isEmpty else {
            throw ADBError.streamFailed("截图失败")
        }
        return data
    }

    // MARK: - sync 协议（传文件）

    /// 一条 sync 消息：id(4) + 长度LE(4) + 内容。
    private func syncMessage(id: String, payload: Data) -> Data {
        var out = Data(id.utf8)
        out.appendLE(UInt32(payload.count))
        out.append(payload)
        return out
    }

    private func le32(_ value: UInt32) -> Data {
        var d = Data()
        d.appendLE(value)
        return d
    }

    /// 读一条 sync 回包：id(4) + 长度LE(4) + 内容。
    private func readSyncResponse(from stream: ADBStream) async throws -> (id: String, message: String) {
        let header = try await stream.readExactly(8)
        let id = String(decoding: header.prefix(4), as: UTF8.self)
        let length = header.uint32LE(at: 4)
        guard length <= 1024 * 1024 else {
            throw ADBError.streamFailed("回包过大")
        }
        let payload = length > 0 ? try await stream.readExactly(Int(length)) : Data()
        return (id, String(decoding: payload, as: UTF8.self))
    }

    /// 把本地文件推到盒子上。
    private func push(localURL: URL, remotePath: String) async throws {
        let data = try Data(contentsOf: localURL)
        let stream = try await open("sync:")
        do {
            // SEND：内容 = 路径 + 模式（0100644）。
            let sendPayload = Data(remotePath.utf8) + le32(0o100644)
            try await stream.write(syncMessage(id: "SEND", payload: sendPayload))
            // DATA：分块传。
            var offset = 0
            while offset < data.count {
                let end = min(offset + 65536, data.count)
                try await stream.write(syncMessage(id: "DATA", payload: data[offset..<end]))
                offset = end
            }
            // DONE：内容 = 文件总大小。
            try await stream.write(syncMessage(id: "DONE", payload: le32(UInt32(data.count))))
            let resp = try await readSyncResponse(from: stream)
            guard resp.id == "OKAY" else {
                throw ADBError.streamFailed(resp.message.isEmpty ? "推送文件失败" : resp.message)
            }
        } catch {
            try? await stream.close()
            throw error
        }
        try await stream.close()
    }
}
