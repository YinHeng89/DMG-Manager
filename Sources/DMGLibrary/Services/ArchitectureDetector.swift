import Foundation

/// 直接读取 Mach-O 头判断架构，不依赖 `file` / `lipo` 等外部命令。
///
/// 支持：
/// - 单架构 Mach-O（MH_MAGIC / MH_MAGIC_64，含大端序）
/// - 通用二进制（FAT_MAGIC / FAT_MAGIC_64）
enum ArchitectureDetector {
    private static let fatMagic: UInt32   = 0xCAFEBABE
    private static let fatMagic64: UInt32 = 0xCAFEBABF
    private static let mhMagic64: UInt32  = 0xFEEDFACF
    private static let mhMagic32: UInt32  = 0xFEEDFACE

    /// 返回可执行文件中包含的所有 cpu type。
    ///
    /// Mach-O 魔数以大端形式存储在文件里；本机是小端序，直接读出来的是字节交换后的值，
    /// 因此统一先 `byteSwapped` 还原成标准魔数再比。这样无需区分「BE / 小端」两条分支，
    /// 也避免误删看似 fallback 的交换路径。
    static func cpuTypes(at url: URL) -> Set<UInt32> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 4096), header.count >= 8 else { return [] }

        return header.withUnsafeBytes { buffer -> Set<UInt32> in
            guard let base = buffer.baseAddress else { return [] }
            // 文件大端存储 → 本机小端读取后需交换字节还原标准魔数。
            let magic = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self).byteSwapped

            switch magic {
            case fatMagic, fatMagic64:
                return cpuTypesFromFat(base: base, count: header.count, is64: magic == fatMagic64)
            case mhMagic64, mhMagic32:
                let cpuType = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self).byteSwapped
                return [cpuType]
            default:
                return []
            }
        }
    }

    static func architecture(at url: URL) -> Architecture {
        Architecture.make(archs: cpuTypes(at: url))
    }

    private static func cpuTypesFromFat(
        base: UnsafeRawPointer,
        count: Int,
        is64: Bool
    ) -> Set<UInt32> {
        let nfatRaw = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let nfat = Int(nfatRaw.byteSwapped)
        let archSize = is64 ? 32 : 20
        var result: Set<UInt32> = []

        for index in 0..<min(nfat, 32) {
            let offset = 8 + index * archSize
            guard offset + 4 <= count else { break }
            let raw = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            result.insert(raw.byteSwapped)
        }
        return result
    }
}
