import SwiftUI

struct ItemListView: View {
    @Environment(LibraryStore.self) private var store
    @State private var pendingDelete: Set<Int64> = []

    var body: some View {
        List(selection: Binding(
            get: { store.selectedItemID },
            set: { store.selectedItemID = $0 }
        )) {
            ForEach(store.filteredItems) { item in
                ItemRow(item: item)
                    .tag(item.id)
                    .contextMenu { itemContextMenu(for: item) }
            }
        }
        .listStyle(.plain)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: Int64.self) { ids in
            if let id = ids.first, let item = store.item(id: id) {
                itemContextMenu(for: item)
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
    @Environment(LibraryStore.self) private var store
    let item: DMGItem

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
        .padding(.vertical, 4)
    }
}

struct ItemGridView: View {
    @Environment(LibraryStore.self) private var store

    private let columns = [GridItem(.adaptive(minimum: 112, maximum: 160), spacing: 16)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 18) {
                ForEach(store.filteredItems) { item in
                    GridCard(item: item, isSelected: store.selectedItemID == item.id)
                        .onTapGesture { store.selectedItemID = item.id }
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
                        .offset(x: 4, y: -4)
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
        .frame(width: 132)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(isSelected ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(isSelected ? Color.accentColor : .clear, lineWidth: 1.5)
        )
    }
}
