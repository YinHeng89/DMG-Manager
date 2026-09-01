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
///
/// 渲染的是 `displayedItems` 而不是 `filteredItems`：同一个软件只占一行，
/// 其余版本在详情的「版本库」里切换。
struct ItemListView: View {
    @Environment(LibraryStore.self) private var store
    /// 列表里点的这一下，目标一定已经可见，不需要滚动定位；用这个标记跳过随后的 scrollTo。
    @State private var suppressScroll = false
    /// 待确认删除的条目 ID 集合：Delete 键或右键「从资料库移除」先暂存到这里，
    /// 经 confirmationDialog 二次确认后才真正执行，避免一次误触丢失用户维护的认知数据。
    @State private var pendingDeleteIDs: Set<Int64>? = nil

    var body: some View {
        // 用 let 接住再进闭包：在 ForEach 里直接访问这个属性会每行求值一次，
        // 而它内部要在 items 里线性查找，整段就退化成 O(n²)。
        let highlightByGroup = store.shouldCollapseVersions
        let selectedKey = store.selectedGroupKey
        let selectedID = store.selectedItemID

        let items = store.displayedItems
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 5) {
                    ForEach(0..<items.count, id: \.self) { index in
                        makeRow(items[index], index: index,
                                highlightByGroup: highlightByGroup,
                                selectedKey: selectedKey,
                                selectedID: selectedID)
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
            if !ids.isEmpty { pendingDeleteIDs = ids }
        }
        .confirmationDialog(
            pendingDeleteIDs.map { Preferences.shared.t("remove.confirmTitle", $0.count) }
                ?? Preferences.shared.t("remove.confirmTitleFallback"),
            isPresented: Binding(
                get: { pendingDeleteIDs != nil },
                set: { if !$0 { pendingDeleteIDs = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button(Preferences.shared.t("remove.button"), role: .destructive) {
                if let ids = pendingDeleteIDs {
                    store.delete(ids: ids, moveToTrash: false)
                }
                pendingDeleteIDs = nil
            }
            Button(Preferences.shared.t("remove.cancel"), role: .cancel) { pendingDeleteIDs = nil }
        }
    }

    /// 抽取成独立方法，避免 ForEach 内联闭包过于复杂触发 Swift 类型检查器超时。
    private func makeRow(_ item: DMGItem, index: Int, highlightByGroup: Bool, selectedKey: String?, selectedID: Int64?) -> some View {
        ItemRow(
            item: item,
            isSelected: highlightByGroup
                ? (item.groupingKey == selectedKey)
                : (item.id == selectedID),
            isAlternate: index % 2 == 1,
            versionCount: store.versionCount(for: item)
        )
        .id(item.id)
        .contentShape(Rectangle())
        .onTapGesture {
            suppressScroll = true
            // 折叠开启时：点一行等于选中「这个软件」——切到它的代表项（最新版本）；
            // 关闭时（重复文件 / 失联）：每一行是独立文件，按精确 id 选中，
            // 避免点一份重复文件把同组全部点亮。
            store.selectedItemID = highlightByGroup
                ? store.representativeID(for: item.id)
                : item.id
        }
        .contextMenu { itemContextMenu(for: item) }
    }

    @ViewBuilder
    private func itemContextMenu(for item: DMGItem) -> some View {
        Button {
            store.open(item)
        } label: {
            Label(Preferences.shared.t("ctx.openDmg"), systemImage: "arrow.up.forward.square")
        }
        .disabled(!item.exists)

        Button {
            store.revealInFinder(item)
        } label: {
            Label(Preferences.shared.t("ctx.showInFinder"), systemImage: "folder")
        }
        .disabled(!item.exists)

        Button {
            store.copyPath(item)
        } label: {
            Label(Preferences.shared.t("action.copyPath"), systemImage: "doc.on.doc")
        }

        Divider()

        Button {
            store.toggleFavorite(id: item.id)
        } label: {
            Label(item.favorite ? Preferences.shared.t("detail.fav.on") : Preferences.shared.t("detail.fav.off"),
                  systemImage: item.favorite ? "star.slash" : "star")
        }

        Button {
            Task { await store.mount(item) }
        } label: {
            Label(Preferences.shared.t("ctx.mountDmg"), systemImage: "externaldrive.badge.plus")
        }
        .disabled(!item.exists || store.mountedVolumes[item.id] != nil)

        Button {
            Task { await store.reparse(ids: [item.id]) }
        } label: {
            Label(Preferences.shared.t("footer.reparse"), systemImage: "arrow.triangle.2.circlepath")
        }

        Divider()

        Button(role: .destructive) {
            pendingDeleteIDs = [item.id]
        } label: {
            Label(Preferences.shared.t("remove.fromLibrary.title"), systemImage: "trash")
        }
    }
}

/// 列表里的一行：图标 + 名称 + 元信息 + 状态。
struct ItemRow: View {
    let item: DMGItem
    var isSelected = false
    /// 斑马纹（原来是 `alternatingRowBackgrounds`，这里自己画，避免依赖 List）。
    var isAlternate = false
    /// 这个软件一共有几个版本（含当前这条）。> 1 时显示提示，
    /// 否则用户会以为折叠掉的那些版本凭空消失了。
    var versionCount = 1

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
                    if versionCount > 1 {
                        Text(Preferences.shared.t("version.count", versionCount))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 1)
                            .background(.quaternary.opacity(0.6), in: Capsule())
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
        // 同 ItemListView：先用 let 接住，避免在 ForEach 里每行重复求值
        let highlightByGroup = store.shouldCollapseVersions
        let selectedKey = store.selectedGroupKey
        let selectedID = store.selectedItemID

        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(store.displayedItems) { item in
                    GridCard(
                        item: item,
                        isSelected: highlightByGroup
                            ? (item.groupingKey == selectedKey)
                            : (item.id == selectedID),
                        versionCount: store.versionCount(for: item)
                    )
                    .contextMenu {
                        Button(Preferences.shared.t("ctx.openDmg")) { store.open(item) }
                        Button(Preferences.shared.t("ctx.showInFinder")) { store.revealInFinder(item) }
                        Button(item.favorite ? Preferences.shared.t("detail.fav.on") : Preferences.shared.t("detail.fav.off")) { store.toggleFavorite(id: item.id) }
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
    var versionCount = 1

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

            if versionCount > 1 {
                Text("共 \(versionCount) 个版本")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

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
        .onTapGesture {
            store.selectedItemID = store.shouldCollapseVersions
                ? store.representativeID(for: item.id)
                : item.id
        }
    }

    private var selectionFill: Color {
        if isSelected { return Color.accentColor.opacity(0.16) }
        if isHovered { return Color.primary.opacity(0.05) }
        return Color.clear
    }
}
