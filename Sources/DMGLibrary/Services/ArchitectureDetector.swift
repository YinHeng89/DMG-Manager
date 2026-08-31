import Foundation

/// 直接读取 Mach-O 头判断架构，不依赖 `file` / `lipo` 等外部命令。
///
/// 支持：
/// - 单架构 Mach-O（MH_MAGIC / MH_MAGIC_64，含大端序）
/// - 通用二进制（FAT_MAGIC / FAT_MAGIC_64）
enum ArchitectureDetector {
    private static let fatMagicBE: UInt32 = 0xCAFE_BABE
    private static let fatMagic64BE: UInt32 = 0xCAFE_BABF
    private static let mhMagicBE64: UInt32 = 0xFEED_FACF
    private static let mhMagicBE32: UInt32 = 0xFEED_FACE

    /// 返回可执行文件中包含的所有 cpu type。
    static func cpuTypes(at url: URL) -> Set<UInt32> {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }

        guard let header = try? handle.read(upToCount: 4096), header.count >= 8 else { return [] }

        return header.withUnsafeBytes { buffer -> Set<UInt32> in
            guard let base = buffer.baseAddress else { return [] }
            let magic = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self)

            switch magic {
            case fatMagicBE, fatMagic64BE:
                return cpuTypesFromFat(base: base, count: header.count, is64: magic == fatMagic64BE)
            case mhMagicBE64, mhMagicBE32:
                let cpuType = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
                return [cpuType]
            default:
                // 小端序：字节交换后重试
                let swapped = magic.byteSwapped
                switch swapped {
                case fatMagicBE, fatMagic64BE:
                    return cpuTypesFromFat(base: base, count: header.count, is64: swapped == fatMagic64BE, swap: true)
                case mhMagicBE64, mhMagicBE32:
                    return [base.loadUnaligned(fromByteOffset: 4, as: UInt32.self).byteSwapped]
                default:
                    return []
                }
            }
        }
    }

    static func architecture(at url: URL) -> Architecture {
        Architecture.make(archs: cpuTypes(at: url))
    }

    private static func cpuTypesFromFat(
        base: UnsafeRawPointer,
        count: Int,
        is64: Bool,
        swap: Bool = false
    ) -> Set<UInt32> {
        let nfatRaw = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self)
        let nfat = Int(swap ? nfatRaw.byteSwapped : nfatRaw)
        let archSize = is64 ? 32 : 20
        var result: Set<UInt32> = []

        for index in 0..<min(nfat, 32) {
            let offset = 8 + index * archSize
            guard offset + 4 <= count else { break }
            let raw = base.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            result.insert(swap ? raw.byteSwapped : raw)
        }
        return result
    }
}
