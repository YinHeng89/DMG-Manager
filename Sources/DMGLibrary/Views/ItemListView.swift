import SwiftUI

/// 中间列的列表。
///
/// 这里刻意不用 SwiftUI 的 `List`：macOS 上 `List` 底层是 `NSTableView`，
/// 它会把自己的 intrinsicContentSize 塞进 NavigationSplitView 的约束系统。
/// 行内容一变宽（解析完成后出现长版本号、标签、「旧版本 · 已装 X」这类长徽章），
/// 中间列就有了很大的硬最小宽度；拖动分栏撞上这个约束时布局会崩——
/// 内容顶进标题栏（顶部横线消失）、竖分隔线贯穿整个窗口。
///
/// 换成 `ScrollView + LazyVStack` 后，中间列和「空白状态 / 解析中」一样轻：
/// 不参与分栏约束、不撑最小宽度，宽度不够就裁切，永远不会触发约束冲突。
struct ItemListView: View {
    @Environment(LibraryStore.self) private var store
    /// 列表里点的这一下，目标一定已经可见，不需要滚动定位；用这个标记跳过随后的 scrollTo。
    @State private var suppressScroll = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(store.filteredItems.enumerated()), id: \.element.id) { index, item in
                        ItemRow(
                            item: item,
                            isSelected: store.selectedItemID == item.id,
                            isAlternate: index % 2 == 1
                        )
                        .id(item.id)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            suppressScroll = true
                            store.selectedItemID = item.id
                        }
                        .contextMenu { itemContextMenu(for: item) }
                    }
                }
                .padding(.vertical, 4)
            }
            // 外部（搜索、菜单栏、详情里的版本跳转）改选中项时滚动到可见区域
            .onChange(of: store.selectedItemID) { _, newID in
                guard let newID else { return }
                if suppressScroll {
                    suppressScroll = false
                    return
                }
                proxy.scrollTo(newID)
            }
        }
        .onDeleteCommand {
            let ids = Set(store.selectedItemID.map { [$0] } ?? [])
            if !ids.isEmpty { store.delete(ids: ids, moveToTrash: false) }
        }
    }

    @ViewBuilder
    private func itemContextMenu(for item: DMGItem) -> some View {
        Button {
            store.open(item)
        } label: {
            Label("打开 DMG", systemImage: "arrow.up.forward.square")
        }
        .disabled(!item.exists)

        Button {
            store.revealInFinder(item)
        } label: {
            Label("在 Finder 中显示", systemImage: "folder")
        }
        .disabled(!item.exists)

        Button {
            store.copyPath(item)
        } label: {
            Label("复制路径", systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            store.toggleFavorite(id: item.id)
        } label: {
            Label(item.favorite ? "取消收藏" : "收藏", systemImage: item.favorite ? "star.slash" : "star")
        }

        Button {
            Task { await store.mount(item) }
        } label: {
            Label("挂载 DMG", systemImage: "externaldrive.badge.plus")
        }
        .disabled(!item.exists || store.mountedVolumes[item.id] != nil)

        Button {
            Task { await store.reparse(ids: [item.id]) }
        } label: {
            Label("重新解析", systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        Button(role: .destructive) {
            store.delete(ids: [item.id], moveToTrash: false)
        } label: {
            Label("从资料库移除", systemImage: "trash")
        }
    }
}

/// 列表里的一行：图标 + 名称 + 元信息 + 状态。
struct ItemRow: View {
    let item: DMGItem
    var isSelected = false
    /// 斑马纹（原来是 `alternatingRowBackgrounds`，这里自己画，避免依赖 List）。
    var isAlternate = false

    @State private var isHovered = false

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(filename: item.iconFilename, size: 36)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(item.effectiveDisplayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    if item.favorite {
                        Image(systemName: "star.fill")
                            .font(.caption2)
                            .foregroundStyle(.yellow)
                    }
                }

                HStack(spacing: 6) {
                    if let version = item.version, !version.isEmpty {
                        Text(version)
                    }
                    Text("·")
                    Text(ByteFormatter.string(fromBytes: item.fileSize))
                    if !item.tags.isEmpty {
                        Text("·")
                        Text(item.tags.prefix(2).joined(separator: " / "))
                            .lineLimit(1)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                ArchitectureBadge(architecture: item.architecture)
                StatusBadge(item: item)
            }
        }
        // 允许这一行被压缩：宽度不够时自己裁切，而不是把列撑开
        .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(rowFill)
                .padding(.horizontal, 6)
        )
        .onHover { isHovered = $0 }
    }

    private var rowFill: Color {
        if isSelected { return Color.accentColor.opacity(0.18) }
        if isHovered { return Color.primary.opacity(0.06) }
        if isAlternate { return Color.primary.opacity(0.03) }
        return Color.clear
    }
}

struct ItemGridView: View {
    @Environment(LibraryStore.self) private var store

    private let columns = [GridItem(.adaptive(minimum: 150, maximum: 220), spacing: 18)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(store.filteredItems) { item in
                    GridCard(item: item, isSelected: store.selectedItemID == item.id)
                        .contextMenu {
                            Button("打开 DMG") { store.open(item) }
                            Button("在 Finder 中显示") { store.revealInFinder(item) }
                            Button(item.favorite ? "取消收藏" : "收藏") { store.toggleFavorite(id: item.id) }
                        }
                }
            }
            .padding(16)
        }
    }
}

struct GridCard: View {
    @Environment(LibraryStore.self) private var store
    @State private var isHovered = false
    let item: DMGItem
    let isSelected: Bool

    var body: some View {
        VStack(spacing: 8) {
            ZStack(alignment: .topTrailing) {
                AppIconView(filename: item.iconFilename, size: 64)
                if item.favorite {
                    Image(systemName: "star.fill")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                        .padding(3)
                        .background(.thickMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(.quaternary, lineWidth: 0.5))
                }
            }

            Text(item.effectiveDisplayName)
                .font(.callout.weight(.medium))
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .frame(height: 32, alignment: .top)

            Text(item.version ?? item.filename.deletingDMGExtension)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            StatusBadge(item: item)
        }
        .padding(10)
        .frame(maxWidth: .infinity)
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(selectionFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(
                    isSelected ? Color.accentColor : (isHovered ? Color.primary.opacity(0.2) : .clear),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .onHover { isHovered = $0 }
        .onTapGesture { store.selectedItemID = item.id }
    }

    private var selectionFill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovered { return Color.primary.opacity(0.05) }
        return Color.clear
    }
}
