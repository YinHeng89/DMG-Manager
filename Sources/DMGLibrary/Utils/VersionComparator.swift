import Foundation

/// 语义化版本号比较：逐段比较数字，数字段优先于预发布段。
///
/// 支持 `139.0.7258.76`、`1.0-beta`、`v2.0` 这类常见写法。
enum VersionComparator {
    static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        if lhs == rhs { return .orderedSame }
        let left = tokenize(lhs)
        let right = tokenize(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : .numeric(0)
            let r = index < right.count ? right[index] : .numeric(0)
            switch (l, r) {
            case (.numeric(let a), .numeric(let b)):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            case (.numeric, .prerelease):
                // 1.0 > 1.0-beta
                return .orderedDescending
            case (.prerelease, .numeric):
                return .orderedAscending
            case (.prerelease(let a), .prerelease(let b)):
                if a != b { return a < b ? .orderedAscending : .orderedDescending }
            }
        }
        return .orderedSame
    }

    private enum Token: Equatable {
        case numeric(Int)
        case prerelease(String)
    }

    /// 把 `v1.2.3-beta.1` 拆成 [1, 2, 3, beta, 1]。
    private static func tokenize(_ raw: String) -> [Token] {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if text.hasPrefix("v") { text.removeFirst() }
        // 只保留第一段（build 号之类用 + 连接的后缀忽略）
        if let plus = text.firstIndex(of: "+") { text = String(text[..<plus]) }

        return text.split(whereSeparator: { $0 == "." || $0 == "-" || $0 == "_" }).map { part in
            if let number = Int(part) { return .numeric(number) }
            // "3beta" 这类：拆出前导数字
            let digits = part.prefix(while: { $0.isNumber })
            if !digits.isEmpty, let number = Int(digits) { return .numeric(number) }
            return .prerelease(String(part))
        }
    }
}
