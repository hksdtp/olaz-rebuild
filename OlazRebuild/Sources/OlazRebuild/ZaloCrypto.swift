import CryptoKit
import Foundation

/// `$znode.crypto.encrypt/decrypt`: the renderer's AES wrapper (preload `E(...)`):
/// `(algorithm, key, iv, aad|null, data, inputEncoding?, outputEncoding?)`.
/// Zalo uses `aes-256-gcm` for its log/param envelope; node:crypto appends the
/// 16-byte tag to the ciphertext, which is what the renderer expects back.
enum ZaloCrypto {
    static func run(encrypt: Bool, args: [Any]) -> Any? {
        let algorithm = (args.first as? String) ?? "aes-256-gcm"
        guard algorithm.hasSuffix("-gcm") else { return nil }
        guard let key = bytes(args.count > 1 ? args[1] : nil),
              let ivData = bytes(args.count > 2 ? args[2] : nil) else { return nil }
        let aad = bytes(args.count > 3 ? args[3] : nil)

        var plain = bytes(args.count > 4 ? args[4] : nil) ?? Data()
        if args.count > 5, (args[5] as? String) == "hex",
           let hex = Data(hexEncoded: (args[4] as? String) ?? "") {
            plain = hex
        }

        let symmetric = SymmetricKey(data: key)
        var result: Data?
        if encrypt {
            if let aad {
                result = try? AES.GCM.seal(plain, using: symmetric, nonce: AES.GCM.Nonce(data: ivData), authenticating: aad).combined
            } else {
                result = try? AES.GCM.seal(plain, using: symmetric, nonce: AES.GCM.Nonce(data: ivData)).combined
            }
        } else {
            // node:crypto expects `ciphertext || tag`.
            guard plain.count > 16 else { return nil }
            let body = plain.prefix(plain.count - 16)
            let tag = plain.suffix(16)
            if let sealed = try? AES.GCM.SealedBox(nonce: AES.GCM.Nonce(data: ivData), ciphertext: body, tag: tag) {
                result = aad.flatMap { try? AES.GCM.open(sealed, using: symmetric, authenticating: $0) }
                    ?? (try? AES.GCM.open(sealed, using: symmetric))
            }
        }
        guard let result else { return nil }
        return ["__bytes": result.base64EncodedString(), "__arraybuffer": true]
    }

    private static func bytes(_ value: Any?) -> Data? {
        if let dict = value as? [String: Any], let base64 = dict["__bytes"] as? String {
            return Data(base64Encoded: base64)
        }
        if let string = value as? String { return Data(string.utf8) }
        if let list = value as? [Any] { return Data(list.compactMap { ($0 as? NSNumber)?.uint8Value }) }
        return nil
    }
}

extension Data {
    init?(hexEncoded string: String) {
        guard string.count % 2 == 0 else { return nil }
        var data = Data(capacity: string.count / 2)
        var index = string.startIndex
        while index < string.endIndex {
            let next = string.index(index, offsetBy: 2)
            guard let byte = UInt8(string[index..<next], radix: 16) else { return nil }
            data.append(byte)
            index = next
        }
        self = data
    }
}
