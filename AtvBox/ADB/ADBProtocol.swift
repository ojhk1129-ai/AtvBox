import Foundation

/// ADB 传输协议（system/core/adb/protocol.txt）
/// 消息头 24 字节，全部小端：
/// command(4) arg0(4) arg1(4) data_length(4) data_checksum(4) magic(4)
/// magic = command ^ 0xffffffff，checksum = payload 所有字节之和。
enum ADB {
    static let version: UInt32 = 0x01000000
    static let maxData: UInt32 = 65536

    static let aSync: UInt32 = 0x434e5953 // "SYNC"
    static let aCnxn: UInt32 = 0x4e584e43 // "CNXN"
    static let aAuth: UInt32 = 0x48545541 // "AUTH"
    static let aOpen: UInt32 = 0x4e45504f // "OPEN"
    static let aOkay: UInt32 = 0x59414b4f // "OKAY"
    static let aClse: UInt32 = 0x45534c43 // "CLSE"
    static let aWrte: UInt32 = 0x45545257 // "WRTE"

    static let authToken: UInt32 = 1
    static let authSignature: UInt32 = 2
    static let authRSAPublicKey: UInt32 = 3
}

struct ADBMessage {
    var command: UInt32
    var arg0: UInt32
    var arg1: UInt32
    var data: Data

    var checksum: UInt32 {
        var sum: UInt32 = 0
        for b in data { sum &+= UInt32(b) }
        return sum
    }

    func encoded() -> Data {
        var out = Data()
        out.appendLE(command)
        out.appendLE(arg0)
        out.appendLE(arg1)
        out.appendLE(UInt32(data.count))
        out.appendLE(checksum)
        out.appendLE(command ^ 0xffffffff)
        out.append(data)
        return out
    }
}

extension Data {
    mutating func appendLE(_ value: UInt32) {
        var v = value.littleEndian
        append(Data(bytes: &v, count: 4))
    }

    func uint32LE(at offset: Int) -> UInt32 {
        let v: UInt32 = withUnsafeBytes { $0.load(fromByteOffset: offset, as: UInt32.self) }
        return UInt32(littleEndian: v)
    }
}

extension String {
    /// ADB 的 OPEN 目标字符串以 NUL 结尾。
    var adbCString: Data {
        var d = Data(self.utf8)
        d.append(0)
        return d
    }
}
