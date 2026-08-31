import SwiftUI
import UniformTypeIdentifiers

/// App 图标：优先用从 DMG 提取出来的图标，没有就回落到光盘符号。
struct AppIconView: View {
    let filename: String?
    var size: CGFloat = 36

    var body: some View {
        Group {
            if let image = IconStore.shared.image(named: filename) {
                Image(nsImage: image)
                    .resizable()
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
    }
}

/// 解析状态 / 安装状态徽章。未解析完成时优先显示解析状态。
struct StatusBadge: View {
    let item: DMGItem

    var body: some View {
        if !item.exists {
            badge("文件失联", symbol: "exclamationmark.triangle.fill", color: .orange)
        } else if item.parseStatus == .parsing {
            badge("解析中", symbol: "arrow.triangle.2.circlepath", color: .blue)
        } else if item.parseStatus == .pending {
            badge("等待解析", symbol: "clock", color: .secondary)
        } else if item.parseStatus == .failed {
            badge("解析失败", symbol: "exclamationmark.triangle.fill", color: .red)
        } else if item.parseStatus == .missing {
            badge("文件失联", symbol: "questionmark.folder.fill", color: .orange)
        } else if item.parseStatus == .noApp {
            badge("无 App", symbol: "doc.circle", color: .secondary)
        } else {
            switch item.installStatus {
            case .installed:
                badge("已安装", symbol: "checkmark.circle.fill", color: .green)
            case .outdated(let version):
                badge("旧版本 · 已装 \(version)", symbol: "arrow.down.circle.fill", color: .blue)
            case .newerThanInstalled(let version):
                badge("可升级 · 已装 \(version)", symbol: "arrow.up.circle.fill", color: .purple)
            case .notInstalled:
                badge("未安装", symbol: "circle", color: .secondary)
            case .unknown:
                badge(item.parseStatus.displayName, symbol: item.parseStatus.symbolName, color: .secondary)
            }
        }
    }

    @ViewBuilder
    private func badge(_ text: String, symbol: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: symbol)
            Text(text)
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

/// 标签小胶囊。
struct TagChip: View {
    let name: String
    var isRemovable = false
    var onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: 4) {
            Text(name)
            if isRemovable {
                Button {
                    onRemove?()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 8, weight: .bold))
                }
                .buttonStyle(.plain)
            }
        }
        .font(.caption)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary.opacity(0.6), in: Capsule())
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
