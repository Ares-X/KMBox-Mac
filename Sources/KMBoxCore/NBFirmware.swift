import Foundation
import CryptoKit

/// Parses, but never extracts or executes, the official NB CPIO container.
public struct NBFirmware: Sendable {
    public let data: Data
    public let sha256: String
    public let entries: [String]
    public let warnings: [String]
    public static let maximumBytes = 64 * 1024 * 1024
    // Official HTTPS sample retrieved 2026-09-12. Its ota_info CPIO checksum is stale.
    // This exception is tied to the entire unchanged file, never to a filename/version claim.
    public static let officialSeptember2026SHA = "99fb0a292ee45338991026fd383a5dc52514d7bacb942fa0f3dab3c6f5a0c037"

    public init(url: URL) throws {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= Self.maximumBytes else { throw KMError.invalid("固件大小必须在 1 字节至 64 MiB 之间。") }
        try self.init(data: Data(contentsOf: url))
    }

    public init(data: Data) throws {
        guard !data.isEmpty, data.count <= Self.maximumBytes else { throw KMError.invalid("固件大小无效。") }
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let bytes = [UInt8](data)
        var offset = 0, names = Set<String>(), mismatches: [String] = [], trailer = false
        var hasNBMarker = false
        func invalid(_ detail: String) -> KMError { .invalid("不是可接受的 NB 固件包：" + detail) }
        while offset + 110 <= bytes.count {
            guard String(bytes: bytes[offset..<offset + 6], encoding: .ascii) == "070702" else { throw invalid("需要 CRC CPIO 格式。") }
            func field(_ index: Int) throws -> Int {
                let start = offset + 6 + index * 8
                let digits = bytes[start..<start + 8]
                guard digits.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }),
                      let value = Int(String(bytes: digits, encoding: .ascii) ?? "", radix: 16) else {
                    throw invalid("CPIO 数字字段损坏。")
                }
                return value
            }
            let mode = try field(1), size = try field(6), nameSize = try field(11), checksum = try field(12)
            guard (1...256).contains(nameSize), offset + 110 + nameSize <= bytes.count else { throw invalid("文件名越界。") }
            let nameStart = offset + 110
            guard bytes[nameStart + nameSize - 1] == 0,
                  let name = String(bytes: bytes[nameStart..<nameStart + nameSize - 1], encoding: .utf8),
                  !name.contains("\0") else { throw invalid("文件名无效。") }
            let start = (nameStart + nameSize + 3) & ~3
            guard start <= bytes.count, size <= bytes.count - start else { throw invalid("文件内容截断。") }
            let end = start + size
            offset = (end + 3) & ~3
            if name == "TRAILER!!!" {
                guard size == 0, bytes[end...].allSatisfy({ $0 == 0 }) else { throw invalid("尾部存在额外数据。") }
                trailer = true; break
            }
            guard ["ota_info.bin", "d21x_os.itb", "rodata.fatfs", "data.fatfs"].contains(name),
                  names.insert(name).inserted, mode & 0xf000 == 0x8000, size > 0 else {
                throw invalid("文件集合、类型或重复条目不符合 NB 包结构：\(name)")
            }
            let sum = bytes[start..<end].reduce(UInt32(0)) { $0 &+ UInt32($1) }
            if sum != UInt32(checksum) { mismatches.append(name) }
            if name == "d21x_os.itb" {
                hasNBMarker = data.subdata(in: start..<end).range(of: Data("kmboxNB".utf8)) != nil
            }
        }
        guard trailer, names.count == 4, hasNBMarker else { throw invalid("缺少 NB 组件、型号标记或结束标记。") }
        var warnings: [String] = []
        if !mismatches.isEmpty {
            guard hash == Self.officialSeptember2026SHA, mismatches == ["ota_info.bin"] else {
                throw invalid("CPIO 校验和不符：" + mismatches.joined(separator: ", "))
            }
            warnings.append("与官网 2026-09-03 样本 SHA-256 完全一致；该官方包的 ota_info.bin 存在已知 CPIO 校验和差异。原包保持不变。")
        }
        self.data = data; sha256 = hash; entries = names.sorted(); self.warnings = warnings
    }
}
