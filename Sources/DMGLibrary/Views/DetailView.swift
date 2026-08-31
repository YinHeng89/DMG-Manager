import SwiftUI
import UniformTypeIdentifiers

struct DetailPane: View {
    @Environment(LibraryStore.self) private var store
    let item: DMGItem?

    var body: some View {
        Group {
            if let item {
                DetailEditor(item: item)
                    .id(item.id) // 切换选中项时重建编辑状态
            } else {
                ContentUnavailableView {
                    Label("未选择安装包", systemImage: "opticaldisc")
                } description: {
                    Text("从中间列表里选一个 DMG，这里会显示它的全部信息。")
                }
            }
        }
    }
}

/// 备注保存状态，用于给用户的保存反馈。
enum NoteSaveState {
    case idle
    case saving
    case saved
}

private struct DetailEditor: View {
    @Environment(LibraryStore.self) private var store
    let item: DMGItem

    @State private var draft: DMGItem
    @State private var newTag = ""
    @State private var showRelocate = false
    @State private var confirmInstall = false
    @State private var confirmDelete = false
    @State private var showPreview = false
    @State private var saveState: NoteSaveState = .idle
    @State private var saveTask: Task<Void, Never>?
    @State private var actionMessage: String?
    @State private var showNewCategory = false
    @State private var newCategoryName = ""

    private let dmgTypes = [UTType.dmg]

    init(item: DMGItem) {
        self.item = item
        _draft = State(initialValue: item)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if !item.exists { missingBanner }
                actions
                if item.parseStatus == .failed, let error = item.parseError { parseErrorBanner(error) }
                metadataSection
                noteSection
                tagsSection
                categorySection
                if !relatedVersions.isEmpty { versionSection }
                footerActions
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            if let actionMessage {
                Text(actionMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(8)
                    .frame(maxWidth: .infinity)
                    .background(.bar)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .fileImporter(
            isPresented: $showRelocate,
            allowedContentTypes: dmgTypes
        ) { (result: Result<URL, Error>) in
            if case .success(let url) = result {
                store.relocate(id: item.id, to: url)
                flash("已重新定位到 \(url.lastPathComponent)")
            }
        }
        .confirmationDialog("安装到 /Applications", isPresented: $confirmInstall) {
            Button("安装") {
                Task {
                    do {
                        try await store.installApp(item)
                        flash("已复制到 /Applications")
                    } catch {
                        flash("安装失败：\(error.localizedDescription)")
                    }
                }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("会把 DMG 内的 \(item.appName ?? "App") 复制到 /Applications。已存在的同名 App 会先移到废纸篓。")
        }
        .confirmationDialog("删除", isPresented: $confirmDelete) {
            Button("仅从资料库移除", role: .destructive) {
                store.delete(ids: [item.id], moveToTrash: false)
            }
            Button("移到废纸篓", role: .destructive) {
                store.delete(ids: [item.id], moveToTrash: true)
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("删除后这条记录的名称、备注、标签都会消失。原始 DMG 只有在「移到废纸篓」时才会被删除。")
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            AppIconView(filename: item.iconFilename, size: 72)

            VStack(alignment: .leading, spacing: 6) {
                TextField("显示名称", text: $draft.displayName)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onSubmit { save() }
                    .onChange(of: draft.displayName) { scheduleSave() }

                HStack(spacing: 8) {
                    if let version = item.version, !version.isEmpty {
                        Text("版本 \(version)")
                    }
                    if let build = item.build, !build.isEmpty {
                        Text("(\(build))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.callout)

                HStack(spacing: 8) {
                    ArchitectureBadge(architecture: item.architecture)
                    StatusBadge(item: item)
                }

                Button {
                    draft.favorite.toggle()
                    save()
                } label: {
                    Label(draft.favorite ? "已收藏" : "收藏",
                          systemImage: draft.favorite ? "star.fill" : "star")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(draft.favorite ? .yellow : .secondary)
            }

            Spacer()
        }
    }

    // MARK: - 文件失联

    private var missingBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("文件位置已改变", systemImage: "exclamationmark.triangle.fill")
                .font(.callout.weight(.medium))
                .foregroundStyle(.orange)
            Text("原始路径：\(item.path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Button("重新定位…") { showRelocate = true }
                    .buttonStyle(.borderedProminent)
                Button("自动查找…") {
                    Task {
                        await store.refreshFileStatus()
                        flash(store.item(id: item.id)?.exists == true ? "已自动重新连接" : "没有找到匹配的文件")
                    }
                }
            }
        }
        .padding(12)
        .background(Color.orange.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
    }

    private func parseErrorBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("解析失败", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.red)
                .font(.callout.weight(.medium))
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
    }

    // MARK: - 操作按钮

    private var actions: some View {
        HStack(spacing: 8) {
            ActionButton("打开", symbol: "arrow.up.forward.square") { store.open(item) }
            ActionButton("Finder", symbol: "folder") { store.revealInFinder(item) }
            if store.mountedVolumes[item.id] != nil {
                ActionButton("卸载", symbol: "eject") { store.unmount(item) }
                ActionButton("显示卷", symbol: "externaldrive") { store.revealMountedVolume(item) }
            } else {
                ActionButton("挂载", symbol: "externaldrive.badge.plus") {
                    Task { await store.mount(item) }
                }
            }
            ActionButton("复制路径", symbol: "doc.on.doc") {
                store.copyPath(item)
                flash("路径已复制")
            }
            if item.appRelativePath != nil {
                ActionButton("安装", symbol: "arrow.right.doc.on.clipboard") { confirmInstall = true }
            }
        }
        .disabled(!item.exists)
    }

    // MARK: - 元数据

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "安装包信息", symbol: "info.circle")

            VStack(alignment: .leading, spacing: 6) {
                MetadataRow(label: "原始文件", value: item.filename)
                MetadataRow(label: "大小", value: ByteFormatter.string(fromBytes: item.fileSize))
                if let appName = item.appName { MetadataRow(label: "App 名称", value: appName) }
                if let developer = item.developer { MetadataRow(label: "开发者", value: developer) }
                if let bundleID = item.bundleID { MetadataRow(label: "Bundle ID", value: bundleID, monospaced: true) }
                if let minimumOS = item.minimumOS { MetadataRow(label: "最低系统", value: "macOS \(minimumOS)") }
                if let installed = item.installedVersion {
                    MetadataRow(label: "已安装", value: installed)
                }
                if let modified = item.fileModifiedAt {
                    MetadataRow(label: "修改时间", value: DateFormatterHelper.full.string(from: modified))
                }
                if let sha = item.sha256, !sha.isEmpty {
                    MetadataRow(label: "SHA-256", value: sha, monospaced: true)
                }
                MetadataRow(label: "路径", value: item.path, monospaced: true)
            }
        }
    }

    // MARK: - 备注
    //
    // 编辑 / 预览 两种状态互斥：预览态只读（不可编辑），编辑态才是文本框。

    private var noteSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "note.text").foregroundStyle(.secondary)
                Text("备注").font(.headline)
                Spacer()
                if saveState == .saved {
                    Label("已保存", systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(.green)
                } else if saveState == .saving {
                    Label("保存中…", systemImage: "arrow.triangle.2.circlepath")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Picker("模式", selection: $showPreview) {
                    Text("编辑").tag(false)
                    Text("预览").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 116)
                .controlSize(.small)
            }

            if showPreview {
                // 预览态：只读渲染，不出现任何编辑框
                if let rendered = renderedNote {
                    Text(rendered)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                } else {
                    Text(draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "暂无备注" : draft.note)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                }
            } else {
                // 编辑态：可编辑文本框 + 自动保存
                TextEditor(text: $draft.note)
                    .font(.system(.body, design: .monospaced))
                    .frame(minHeight: 120)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .strokeBorder(saveState == .saving ? Color.accentColor.opacity(0.4) : .clear, lineWidth: 1)
                    )
                    .onChange(of: draft.note) { scheduleSave() }
            }
        }
    }

    private var renderedNote: AttributedString? {
        guard !draft.note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return try? AttributedString(
            markdown: draft.note,
            options: .init(interpretedSyntax: .full, failurePolicy: .returnPartiallyParsedIfPossible)
        )
    }

    // MARK: - 标签
    //
    // 交互优化：当前标签以可删除胶囊呈现；末尾是一个明显的「添加」输入框
    // （回车即添加）；下方「常用标签」用带 + 的胶囊一键追加，与现有标签视觉统一。

    private var tagsSection: some View {
        let suggestions = store.tagCounts
            .map(\.name)
            .filter { !draft.tags.contains($0) }

        return VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "标签", symbol: "tag")

            FlowLayout(spacing: 6) {
                ForEach(draft.tags, id: \.self) { tag in
                    TagChip(name: tag) { removeTag(tag) }
                }

                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("添加标签，回车确认", text: $newTag)
                        .textFieldStyle(.plain)
                        .onSubmit(addTag)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .frame(minWidth: 132)
            }

            if !suggestions.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("常用标签")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    FlowLayout(spacing: 6) {
                        ForEach(suggestions.prefix(16), id: \.self) { name in
                            Button {
                                addExistingTag(name)
                            } label: {
                                Label(name, systemImage: "plus")
                                    .font(.caption)
                            }
                            .buttonStyle(.plain)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.06), in: Capsule())
                        }
                    }
                }
            }
        }
    }

    private func addTag() {
        let tag = newTag.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty, !draft.tags.contains(tag) else {
            newTag = ""
            return
        }
        withAnimation { draft.tags.append(tag) }
        newTag = ""
        save()
    }

    private func addExistingTag(_ name: String) {
        guard !draft.tags.contains(name) else { return }
        withAnimation { draft.tags.append(name) }
        save()
    }

    private func removeTag(_ tag: String) {
        withAnimation { draft.tags.removeAll { $0 == tag } }
        save()
    }

    // MARK: - 分类

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "分类", symbol: "folder")
            FlowLayout(spacing: 6) {
                ForEach(store.allCategories, id: \.self) { category in
                    Button {
                        draft.category = category
                        save()
                    } label: {
                        HStack(spacing: 4) {
                            if draft.category == category {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                            }
                            Text(category)
                        }
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .background(
                            draft.category == category
                                ? Color.accentColor.opacity(0.18)
                                : Color.primary.opacity(0.06),
                            in: Capsule()
                        )
                        .foregroundStyle(draft.category == category ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    showNewCategory = true
                } label: {
                    Image(systemName: "plus")
                        .font(.caption)
                    Text("新建")
                        .font(.caption)
                }
                .buttonStyle(.plain)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(Color.primary.opacity(0.06), in: Capsule())
            }
        }
        .alert("新建分类", isPresented: $showNewCategory) {
            TextField("分类名称", text: $newCategoryName)
            Button("创建") {
                let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { return }
                store.addCategory(name)
                draft.category = name
                save()
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("分类代表「它是什么」；标签代表「它有什么属性」。")
        }
    }

    // MARK: - 版本库

    private var relatedVersions: [DMGItem] {
        store.relatedVersions(for: item)
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "版本库 · \(relatedVersions.count + 1) 个版本", symbol: "clock.arrow.circlepath")

            VStack(spacing: 4) {
                VersionRow(item: item, isCurrent: true)

                ForEach(relatedVersions) { other in
                    Button {
                        store.selectedItemID = other.id
                    } label: {
                        VersionRow(item: other, isCurrent: false)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - 底部

    private var footerActions: some View {
        HStack {
            Button("重新解析") {
                Task { await store.reparse(ids: [item.id]) }
            }
            Spacer()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("删除", systemImage: "trash")
            }
        }
        .padding(.top, 8)
    }

    // MARK: - 保存

    private func save() {
        saveTask?.cancel()
        store.saveMetadata(draft)
        flashSaved()
    }

    /// 文本输入防抖：停止输入 0.6 秒后再落库。
    private func scheduleSave() {
        let snapshot = draft
        saveState = .saving
        saveTask?.cancel()
        saveTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000)
            guard !Task.isCancelled else { return }
            store.saveMetadata(snapshot)
            flashSaved()
        }
    }

    private func flashSaved() {
        saveState = .saved
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            if saveState == .saved { saveState = .idle }
        }
    }

    private func flash(_ message: String) {
        withAnimation { actionMessage = message }
        Task {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            withAnimation { actionMessage = nil }
        }
    }
}

struct ActionButton: View {
    let title: String
    let symbol: String
    let action: () -> Void

    init(_ title: String, symbol: String, action: @escaping () -> Void) {
        self.title = title
        self.symbol = symbol
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.system(size: 15))
                Text(title)
                    .font(.caption2)
            }
            .frame(width: 58, height: 44)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct VersionRow: View {
    let item: DMGItem
    let isCurrent: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(filename: item.iconFilename, size: 22)
            Text(item.version ?? "未知版本")
                .font(.callout)
            if isCurrent {
                Text("当前")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.quaternary.opacity(0.6), in: Capsule())
            }
            Spacer()
            Text(item.filename)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(isCurrent ? Color.accentColor.opacity(0.12) : Color.clear)
        )
    }
}

/// 简单的流式布局：标签个数不固定时比 LazyVGrid 更顺手。
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // 宽度未指定时退化成单行总宽，避免返回 infinity
        let maxWidth = proposal.width ?? sizes.reduce(0) { $0 + $1.width + spacing }

        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0

        for size in sizes {
            if x + size.width > maxWidth, x > 0 {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0

        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
