import SwiftUI
import UniformTypeIdentifiers

/// App 图标：优先用从 DMG 提取出来的图标，没有就回落到光盘符号。
///
/// 图标解码放在后台线程（`IconStore.requestImage`），主线程只走缓存命中——这样选中
/// 切换 / 列表滚动时不会被图标解码卡住。命中缓存时通过 init 同步取，避免首帧闪一下占位图。
struct AppIconView: View {
    let filename: String?
    var size: CGFloat = 36

    @State private var resolved: NSImage?

    init(filename: String?, size: CGFloat = 36) {
        self.filename = filename
        self.size = size
        // 命中缓存时同步取，避免首帧闪一下占位图。
        _resolved = State(initialValue: IconStore.shared.image(named: filename, pointSize: size))
    }

    private var loadKey: String { "\(filename ?? "")|\(Int(size))" }

    var body: some View {
        Group {
            if let resolved {
                Image(nsImage: resolved)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
            } else {
                Image(systemName: "opticaldisc")
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .padding(size * 0.16)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
        .task(id: loadKey) {
            // 缓存未命中时在后台解码，完成后再更新，不阻塞选中高亮的切换。
            IconStore.shared.requestImage(named: filename, pointSize: size) { image in
                resolved = image
            }
        }
    }
}

/// 解析状态 / 安装状态徽章。未解析完成时优先显示解析状态。
struct StatusBadge: View {
    let item: DMGItem
    @Environment(LibraryStore.self) private var store
    @Environment(Preferences.self) private var prefs

    var body: some View {
        // 通过 store.presence（被 Observation 追踪）判断存在性：外部删/恢复文件时才会驱动重绘；
        // 直接读 item.exists 是 computed，不含变化通知，界面会卡在旧状态。
        let exists = store.presence[item.id] ?? item.exists
        if !exists {
            badge(prefs.t("parse.missing"), symbol: "exclamationmark.triangle.fill", color: .orange)
        } else if item.parseStatus == .parsing {
            badge(prefs.t("parse.parsing"), symbol: "arrow.triangle.2.circlepath", color: .blue)
        } else if item.parseStatus == .pending {
            badge(prefs.t("parse.pending"), symbol: "clock", color: .secondary)
        } else if item.parseStatus == .failed {
            badge(prefs.t("parse.failed"), symbol: "exclamationmark.triangle.fill", color: .red)
        } else if item.parseStatus == .noApp {
            badge(prefs.t("parse.noApp"), symbol: "doc.circle", color: .secondary)
        } else {
            switch item.installStatus {
            case .installed:
                badge(prefs.t("install.installed"), symbol: "checkmark.circle.fill", color: .green)
            case .outdated(let version):
                badge(prefs.t("status.outdated.installed", version), symbol: "arrow.down.circle.fill", color: .blue)
            case .newerThanInstalled(let version):
                badge(prefs.t("status.upgrade.installed", version), symbol: "arrow.up.circle.fill", color: .purple)
            case .notInstalled:
                badge(prefs.t("install.notInstalled"), symbol: "circle", color: .secondary)
            case .unknown:
                badge(item.parseStatus.displayName, symbol: item.parseStatus.symbolName, color: .secondary)
            }
        }
    }

    @ViewBuilder
    private func badge(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            // 「旧版本 · 已装 26.825.5151」这类长文本必须能截断，
            // 否则它会撑出行的硬最小宽度，列表列就压不下去。
            Text(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .font(.caption2)
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }
}

struct ArchitectureBadge: View {
    let architecture: Architecture

    var body: some View {
        if architecture != .unknown {
            HStack(spacing: 4) {
                Image(systemName: architecture.symbolName)
                Text(architecture.shortName)
            }
            .font(.caption2)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary.opacity(0.5), in: Capsule())
        }
    }
}

/// 标签小胶囊。悬停时高亮，删除按钮更明显、更好点。
struct TagChip: View {
    let name: String
    var onRemove: (() -> Void)?

    @State private var hovered = false

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
            if onRemove != nil {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .opacity(hovered ? 1 : 0.5)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(
            (onRemove != nil && hovered ? Color.accentColor : Color.primary)
                .opacity((onRemove != nil && hovered) ? 0.14 : 0.06),
            in: Capsule()
        )
        .foregroundStyle((onRemove != nil && hovered) ? Color.accentColor : .primary)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
    }
}

/// 分类小胶囊：点名字把它分配给当前条目，点 × 删掉这个自建分类。
///
/// 删除规则和标签一致——还有条目在用就不许删，避免出现没有分类的条目；
/// 内置预设分类不属于词表，不显示删除按钮。
struct CategoryChip: View {
    let name: String
    let isSelected: Bool
    var onSelect: () -> Void
    /// 为 nil 表示该分类不可删除（内置预设），不显示删除按钮。
    var onDelete: (() -> Void)?
    /// 非 nil 表示「正在使用中」，删除按钮显示为不可点，并在悬停时说明原因。
    var blockedReason: String?

    @State private var hovered = false

    private var canDelete: Bool { onDelete != nil && blockedReason == nil }

    var body: some View {
        HStack(spacing: 4) {
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.caption2.weight(.bold))
            }

            Button(action: onSelect) {
                Text(name)
            }
            .buttonStyle(.plain)

            if onDelete != nil {
                Button { onDelete?() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                }
                .buttonStyle(.plain)
                .disabled(!canDelete)
                .opacity(canDelete ? (hovered ? 1 : 0.5) : 0.25)
                .help(canDelete ? Preferences.shared.t("category.deleteHelp", name) : (blockedReason ?? ""))
            }
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            isSelected ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06),
            in: Capsule()
        )
        .foregroundStyle(isSelected ? Color.accentColor : .primary)
        .onHover { hovered = $0 }
        .animation(.easeInOut(duration: 0.12), value: hovered)
    }
}

/// 详情面板里的键值对。
struct MetadataRow: View {
    let label: String
    let value: String
    var monospaced = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .foregroundStyle(.secondary)
                .frame(width: 76, alignment: .leading)
            Text(value)
                .font(monospaced ? .system(.body, design: .monospaced) : .body)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.callout)
    }
}

/// 面板分区标题。
struct SectionHeader: View {
    let title: String
    var symbol: String?

    var body: some View {
        HStack(spacing: 6) {
            if let symbol {
                Image(systemName: symbol)
                    .foregroundStyle(.secondary)
            }
            Text(title)
                .font(.headline)
            Spacer()
        }
        .padding(.bottom, 2)
    }
}

extension UTType {
    /// `.dmg` 不是系统内置类型，这里统一定义一次，避免各处重复构造。
    static var dmg: UTType { UTType(filenameExtension: "dmg") ?? .data }
}
