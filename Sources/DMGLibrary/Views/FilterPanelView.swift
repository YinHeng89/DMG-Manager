import SwiftUI

struct FilterPanelView: View {
    @Environment(LibraryStore.self) private var store
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Text("高级筛选")
                    .font(.headline)
                Spacer()
                if store.activeFilterCount > 0 {
                    Button("清除全部") {
                        store.filters = FilterCriteria()
                    }
                }
                Button("完成") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    FilterSection("架构", symbol: "cpu") {
                        ToggleChips(
                            selection: Binding(
                                get: { store.filters.architectures },
                                set: { store.filters.architectures = $0 }
                            ),
                            options: [
                                ChipOption(value: Architecture.appleSilicon, title: "Apple Silicon"),
                                ChipOption(value: Architecture.intel, title: "Intel"),
                                ChipOption(value: Architecture.universal, title: "Universal"),
                                ChipOption(value: Architecture.unknown, title: "未知")
                            ]
                        )
                    }

                    FilterSection("安装状态", symbol: "checkmark.circle") {
                        ToggleChips(
                            selection: Binding(
                                get: { Set(store.filters.installStatuses.compactMap(InstallStatusFilter.init)) },
                                set: { store.filters.installStatuses = Set($0.map(\.rawValue)) }
                            ),
                            options: InstallStatusFilter.allCases.map { ChipOption(value: $0, title: $0.title) }
                        )
                    }

                    FilterSection("解析状态", symbol: "waveform.path.ecg") {
                        ToggleChips(
                            selection: Binding(
                                get: { store.filters.parseStatuses },
                                set: { store.filters.parseStatuses = $0 }
                            ),
                            options: ParseStatus.allCases.map { ChipOption(value: $0, title: $0.displayName) }
                        )
                    }

                    if !store.allCategories.isEmpty {
                        FilterSection("分类", symbol: "folder") {
                            TagPicker(
                                options: store.allCategories,
                                selection: Binding(
                                    get: { store.filters.categories },
                                    set: { store.filters.categories = $0 }
                                )
                            )
                        }
                    }

                    if !store.tagCounts.isEmpty {
                        FilterSection("标签", symbol: "tag") {
                            TagPicker(
                                options: store.tagCounts.map(\.name),
                                selection: Binding(
                                    get: { store.filters.requireTags },
                                    set: { store.filters.requireTags = $0 }
                                )
                            )
                        }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 460, height: 460)
    }
}

struct FilterSection<Content: View>: View {
    let title: String
    let symbol: String
    @ViewBuilder var content: Content

    init(_ title: String, symbol: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.symbol = symbol
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.subheadline.weight(.medium))
            content
        }
    }
}

/// 一个可选项。用 struct 而不是元组，方便 SwiftUI 的 ForEach 追踪身份。
struct ChipOption<T: Hashable>: Identifiable {
    let value: T
    let title: String
    var id: T { value }
}

/// 多选胶囊组。空集合代表「不限」。
struct ToggleChips<T: Hashable>: View {
    @Binding var selection: Set<T>
    let options: [ChipOption<T>]

    init(selection: Binding<Set<T>>, options: [ChipOption<T>]) {
        self._selection = selection
        self.options = options
    }

    var body: some View {
        WrapBox {
            ForEach(options) { option in
                Chip(text: option.title, isOn: selection.contains(option.value)) {
                    if selection.contains(option.value) {
                        selection.remove(option.value)
                    } else {
                        selection.insert(option.value)
                    }
                }
            }
        }
    }
}


/// 通用字符串集合选择器。
struct TagPicker: View {
    let options: [String]
    @Binding var selection: Set<String>

    var body: some View {
        WrapBox {
            ForEach(options, id: \.self) { option in
                Chip(text: option, isOn: selection.contains(option)) {
                    if selection.contains(option) {
                        selection.remove(option)
                    } else {
                        selection.insert(option)
                    }
                }
            }
        }
    }
}

struct Chip: View {
    let text: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.callout)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(
                    isOn ? Color.accentColor.opacity(0.2) : Color.secondary.opacity(0.1),
                    in: Capsule()
                )
                .overlay(
                    Capsule().strokeBorder(isOn ? Color.accentColor : .clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .foregroundStyle(isOn ? .primary : .secondary)
    }
}

struct WrapBox: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        // 宽度未指定时退化成单行总宽，避免返回 infinity
        let maxWidth = proposal.width ?? sizes.reduce(0) { $0 + $1.width + spacing }

        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for size in sizes {
            if x + size.width > maxWidth, x > 0 {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for view in subviews {
            let size = view.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX {
                x = bounds.minX; y += rowHeight + spacing; rowHeight = 0
            }
            view.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
