import SwiftUI
import UniformTypeIdentifiers

struct DetailPane: View {
    @Environment(LibraryStore.self) private var store
    let item: DMGItem?

    var body: some View {
        VStack(spacing: 0) {
            if let item {
                // 选中态：固定头部钉在顶部，详情内容在下面滚动
                DetailEditor(item: item)
                    .id(item.id) // 切换选中项时重建编辑状态
            } else {
                // 未选中态：提示在整列居中（和以前一致），固定顶栏作为覆盖层防止竖线穿透
                ZStack(alignment: .top) {
                    ContentUnavailableView {
                        Label("未选择安装包", systemImage: "opticaldisc")
                    } description: {
                        Text("从中间列表里选一个 DMG，这里会显示它的全部信息。")
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    DetailEmptyHeader()
                }
            }
        }
    }
}

/// 详情列未选中时的固定顶栏占位：与选中态等高、同材质，
/// 让这一列顶部始终有固定内容，分栏竖线就不会往上穿透。
/// 具体文字提示由下方居中的 ContentUnavailableView 承载。
private struct DetailEmptyHeader: View {
    /// 对齐选中态固定头部的高度：图标行 44 + 徽章行 20 + 操作按钮 44 + 间距/内边距约 40。
    /// 操作按钮排在很窄的详情列里会换行，那时实际高度更大——占位只差一截，
    /// 反正它的唯一职责是让这一列顶部始终有固定内容、挡住分栏竖线。
    var body: some View {
        Color.clear
            .frame(height: 148)
            .background(.bar)
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
    @State private var showPreview = true
    @State private var saveState: NoteSaveState = .idle
    @State private var saveTask: Task<Void, Never>?
    @State private var actionMessage: String?
    @State private var newCategoryName = ""

    private let dmgTypes = [UTType.dmg]

    init(item: DMGItem) {
        self.item = item
        _draft = State(initialValue: item)
    }

    var body: some View {
        VStack(spacing: 0) {
            // 固定头部：名称 + 徽章 + 操作按钮，整块钉在顶部不随内容滚动
            // （同时充当顶栏，避免分栏竖线穿透）
            VStack(alignment: .leading, spacing: 10) {
                headerRow
                actions
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.bar)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if !item.exists { missingBanner }
                    if item.parseStatus == .failed, let error = item.parseError { parseErrorBanner(error) }
                    metadataSection
                    noteSection
                    tagsSection
                    categorySection
                    if versionGroup.count > 1 { versionSection }
                    footerActions
                }
                .padding(20)
            }
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
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

    // MARK: - 头部（固定区，不滚动）

    /// 图标 + 名称 + 版本 + 架构/状态徽章。文字块在同一条左对齐的列里（图标在左、文字块在右），
    /// 徽章紧跟在版本下面、和名称/版本左对齐——这是本次会话之前（HEAD）的原始排布，
    /// 本会话重构时误把它拆成了单独一行，这里还原。操作按钮在 `actions`（固定头部、不滚动）。
    private var headerRow: some View {
        HStack(alignment: .center, spacing: 12) {
            AppIconView(filename: item.iconFilename, size: 54)

            VStack(alignment: .leading, spacing: 3) {
                TextField("显示名称", text: $draft.displayName)
                    .textFieldStyle(.plain)
                    .font(.title3.weight(.semibold))
                    .onSubmit { save() }
                    .onChange(of: draft.displayName) { scheduleSave() }

                HStack(spacing: 6) {
                    if let version = item.version, !version.isEmpty {
                        Text("版本 \(version)")
                    }
                    if let build = item.build, !build.isEmpty {
                        Text("(\(build))")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption)

                HStack(spacing: 6) {
                    ArchitectureBadge(architecture: item.architecture)
                    StatusBadge(item: item)
                }
            }
            .frame(minWidth: 0)

            Spacer(minLength: 8)

            Button {
                draft.favorite.toggle()
                save()
            } label: {
                Image(systemName: draft.favorite ? "star.fill" : "star")
                    .font(.system(size: 15))
            }
            .buttonStyle(.borderless)
            .foregroundStyle(draft.favorite ? .yellow : .secondary)
            .help(draft.favorite ? "取消收藏" : "收藏")
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

    /// 操作按钮排。常驻在固定头部里（架构徽章下面），不随下面的信息滚动。
    ///
    /// 用 FlowLayout 而不是 HStack：HStack 里 6 个固定宽按钮会形成
    /// 「硬最小宽度」，详情列压不下去；空间一紧张 NSSplitView 就会
    /// 自动折叠侧边栏，布局直接崩。换成流式布局后窄宽度自动换行。
    /// 每个按钮内部是「图标在左、文字在右」的横排（见 ActionButton）。
    private var actions: some View {
        FlowLayout(spacing: 8) {
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
                    Text("预览").tag(true)
                    Text("编辑").tag(false)
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
                    TextField("添加标签", text: $newTag)
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

    /// 只有自建分类（在分类词表里）才提供删除，内置预设不显示删除按钮。
    private func isCustomCategory(_ name: String) -> Bool {
        store.customCategories.contains(name)
    }

    private func deleteCategory(_ name: String) {
        withAnimation { store.deleteCategory(name) }
    }

    // MARK: - 分类

    private var categorySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "分类", symbol: "folder")
            FlowLayout(spacing: 6) {
                ForEach(store.allCategories, id: \.self) { category in
                    CategoryChip(
                        name: category,
                        isSelected: draft.category == category,
                        onSelect: {
                            draft.category = category
                            save()
                        },
                        onDelete: isCustomCategory(category) ? { deleteCategory(category) } : nil,
                        blockedReason: store.isCategoryInUse(category)
                            ? "有条目正在使用这个分类，不能删除"
                            : nil
                    )
                }

                // 和「添加标签」保持同一套交互：行内输入、回车即建，不弹模态框。
                HStack(spacing: 4) {
                    Image(systemName: "plus")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("新建分类", text: $newCategoryName)
                        .textFieldStyle(.plain)
                        .onSubmit(addNewCategory)
                }
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(Color.primary.opacity(0.06), in: Capsule())
                .frame(minWidth: 132)
            }
        }
    }

    /// 回车即建：分类不存在时先加进词表，然后直接赋给当前条目。
    private func addNewCategory() {
        let name = newCategoryName.trimmingCharacters(in: .whitespacesAndNewlines)
        newCategoryName = ""
        guard !name.isEmpty else { return }
        store.addCategory(name) // 已存在时内部会忽略
        draft.category = name
        save()
    }

    // MARK: - 版本库

    /// 同一个软件的全部版本（含当前这条），按「最新优先」排好序。
    ///
    /// 列表里只显示代表项（默认最新版本），其余版本从这里切过去——
    /// 一换 selectedItemID，DetailPane 就会用 `.id(item.id)` 重建整个编辑器，
    /// 头部（名称 / 版本 / 架构 / 状态）和「安装包信息」整块跟着换成本版本的数据。
    private var versionGroup: [DMGItem] {
        store.versionGroup(for: item)
    }

    private var versionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionHeader(title: "版本库 · \(versionGroup.count) 个版本", symbol: "clock.arrow.circlepath")

            VStack(spacing: 4) {
                ForEach(versionGroup) { member in
                    Button {
                        store.selectedItemID = member.id
                    } label: {
                        VersionRow(
                            item: member,
                            isCurrent: member.id == item.id,
                            isLatest: member.id == versionGroup.first?.id
                        )
                    }
                    .buttonStyle(.plain)
                    // 不 disable 当前项：禁用会把整行（包括高亮背景）渲染成灰色，
                    // 看起来像不可选。点自己本来就是无副作用的重设同一个 id。
                }
            }

            Text("列表默认显示最新版本，切换后上方信息随之更新。")
                .font(.caption2)
                .foregroundStyle(.tertiary)
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
            HStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 14))
                Text(title)
                    .font(.caption)
            }
            .padding(.horizontal, 10)
            .frame(height: 32)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}

struct VersionRow: View {
    let item: DMGItem
    let isCurrent: Bool
    /// 组内版本最高的那条。列表默认展示的就是它，标出来方便用户认路。
    var isLatest = false

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(filename: item.iconFilename, size: 22)
            Text(item.version ?? "未知版本")
                .font(.callout)
            if isLatest {
                Text("最新")
                    .font(.caption2)
                    .foregroundStyle(.green)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.green.opacity(0.12), in: Capsule())
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
        .contentShape(Rectangle())
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
