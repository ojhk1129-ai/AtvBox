import Foundation
import Security

/// ADB 身份密钥（RSA-2048）。
///
/// 钥匙存在 App 自己的文件里（Application Support/adbkey.p8，PKCS#8 DER），
/// 不走系统钥匙串：LiveContainer 里钥匙串不可靠，钥匙造出来了也签不了名，
/// 第一次连就一直报“签名失败”。盒子只认这一把钥匙，电视上点一次“允许”
/// 以后就不用再点；换钥匙后电视会再弹一次授权框，点允许就行。
/// 公钥格式是 ADB 专用的：base64( mod长度LE(4) + mod大端字节 + 指数LE(4) ) + " atvbox@ios"
/// （对应 AOSP system/core/libcrypto_utils/android_pubkey.c 的编码）。
enum ADBKeyError: Error, LocalizedError {
    case generateFailed(OSStatus)
    case keyNotFound
    case publicKeyFailed
    case signFailed(OSStatus)
    case badPublicKey

    var errorDescription: String? {
        switch self {
        case .generateFailed(let s): return "生成密钥失败（\(s)）"
        case .keyNotFound: return "找不到密钥"
        case .publicKeyFailed: return "读取公钥失败"
        case .signFailed(let s): return "签名失败（\(s)）"
        case .badPublicKey: return "公钥格式不对"
        }
    }
}

final class ADBKeyManager {
    static let shared = ADBKeyManager()

    private var cachedPrivateKey: SecKey?

    /// 私钥文件：Application Support/adbkey.p8。
    private var keyFileURL: URL? {
        guard let dir = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return nil
        }
        return dir.appendingPathComponent("adbkey.p8")
    }

    /// 从 CFError 里取真正的 OSStatus。
    /// 注意：CFError 不能直接 as? OSStatus 转（永远是 nil，以前报错
    /// 才一直显示 -1，真实原因全被盖住了），必须用 CFErrorGetCode。
    private func status(from error: Unmanaged<CFError>?) -> OSStatus {
        guard let cfError = error?.takeRetainedValue() else { return -1 }
        return OSStatus(CFErrorGetCode(cfError))
    }

    /// 取出或生成私钥：先读文件里的，没有就新生成一把并存文件。
    func privateKey() throws -> SecKey {
        if let key = cachedPrivateKey { return key }

        // 1. 文件里有就导进来。
        if let url = keyFileURL,
           let data = try? Data(contentsOf: url),
           !data.isEmpty {
            var error: Unmanaged<CFError>?
            let attrs: [String: Any] = [
                kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
                kSecAttrKeySizeInBits as String: 2048,
            ]
            if let key = SecKeyCreateWithData(
                data as CFData, attrs as CFDictionary, &error) {
                cachedPrivateKey = key
                return key
            }
            // 文件坏了就删掉，重新生成一把（不然每次启动都卡在这）。
            try? FileManager.default.removeItem(at: url)
        }

        // 2. 新生成一把（不进钥匙串，只放内存）。
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits as String: 2048,
            kSecAttrIsPermanent as String: false,
            kSecAttrIsExtractable as String: true,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error) else {
            throw ADBKeyError.generateFailed(status(from: error))
        }
        cachedPrivateKey = key

        // 3. 导出私钥存文件，下次启动直接用同一把（盒子认得，不用重新授权）。
        // 导出失败也不影响这次连接，只是下次启动会换一把，电视再弹一次授权框。
        if let url = keyFileURL,
           let exported = SecKeyCopyExternalRepresentation(key, &error) {
            let dir = url.deletingLastPathComponent()
            try? FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)
            try? (exported as Data).write(to: url, options: .atomic)
        }
        return key
    }

    /// 用 SHA1 + PKCS#1 v1.5 给 20 字节的 token 签名。
    func sign(token: Data) throws -> Data {
        let key = try privateKey()
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            key, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &error) else {
            throw ADBKeyError.signFailed(status(from: error))
        }
        return sig as Data
    }

    /// ADB 格式的公钥字符串。
    func publicKeyString() throws -> String {
        let priv = try privateKey()
        guard let pub = SecKeyCopyPublicKey(priv) else { throw ADBKeyError.publicKeyFailed }
        var error: Unmanaged<CFError>?
        guard let ext = SecKeyCopyExternalRepresentation(pub, &error) else {
            throw ADBKeyError.publicKeyFailed
        }
        let der = ext as Data
        let (modulus, exponent) = try parseRSAPublicKeyDER(der)
        var blob = Data()
        blob.appendLE(UInt32(modulus.count))
        blob.append(modulus)
        blob.appendLE(exponent)
        return blob.base64EncodedString() + " atvbox@ios"
    }

    /// 解析 RSA 公钥 DER（PKCS#1 的 RSAPublicKey；也兼容 X.509 SPKI 包装）。
    private func parseRSAPublicKeyDER(_ der: Data) throws -> (modulus: Data, exponent: UInt32) {
        var bytes = [UInt8](der)
        var pos = 0

        func readLength() throws -> Int {
            guard pos < bytes.count else { throw ADBKeyError.badPublicKey }
            let b = Int(bytes[pos]); pos += 1
            if b & 0x80 == 0 { return b }
            let n = b & 0x7f
            guard n > 0 && n <= 4 && pos + n <= bytes.count else { throw ADBKeyError.badPublicKey }
            var len = 0
            for _ in 0..<n { len = (len << 8) | Int(bytes[pos]); pos += 1 }
            return len
        }
        func readTLV() throws -> (tag: UInt8, content: [UInt8]) {
            guard pos < bytes.count else { throw ADBKeyError.badPublicKey }
            let tag = bytes[pos]; pos += 1
            let len = try readLength()
            guard pos + len <= bytes.count else { throw ADBKeyError.badPublicKey }
            let content = Array(bytes[pos..<(pos + len)])
            pos += len
            return (tag, content)
        }

        // 最外层 SEQUENCE
        let (topTag, topContent) = try readTLV()
        guard topTag == 0x30 else { throw ADBKeyError.badPublicKey }
        var inner = topContent
        var innerPos = 0

        // 如果是 SPKI（第一个元素是算法 SEQUENCE，第二个是 BIT STRING），先解包。
        func peekTag(_ data: [UInt8], _ p: Int) -> UInt8? {
            guard p < data.count else { return nil }
            return data[p]
        }
        if peekTag(inner, innerPos) == 0x30 {
            // 可能是 SPKI：跳过算法 SEQUENCE，再读 BIT STRING
            bytes = inner; pos = innerPos
            _ = try readTLV() // 算法
            let (bitTag, bitContent) = try readTLV()
            guard bitTag == 0x03, !bitContent.isEmpty else { throw ADBKeyError.badPublicKey }
            // BIT STRING 第一个字节是未用位数（0），后面就是 RSAPublicKey DER
            inner = Array(bitContent.dropFirst())
            innerPos = 0
        }

        bytes = inner; pos = innerPos
        let (modTag, modBytes) = try readTLV()
        let (expTag, expBytes) = try readTLV()
        guard modTag == 0x02, expTag == 0x02 else { throw ADBKeyError.badPublicKey }

        // INTEGER 可能带一个前导 0x00（保证正数），去掉它。
        var modulus = modBytes
        if modulus.first == 0x00 { modulus.removeFirst() }
        var exponent: UInt32 = 0
        for b in expBytes { exponent = (exponent << 8) | UInt32(b) }
        return (Data(modulus), exponent)
    }
}
