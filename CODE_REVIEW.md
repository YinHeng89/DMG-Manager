# DMG Library — 完整 Code Review

**审查日期**：2026-09-01
**代码规模**：7,318 行 Swift（32 个源文件）+ 官网前端
**构建状态**：`swift build` 通过，**0 错误 0 警告**
**测试状态**：29 个测试全部通过
**结论**：架构分层清晰、注释质量罕见地高、核心数据流有测试覆盖。但存在 **4 个会直接损害产品核心价值的缺陷**，其中 1 个已实测复现。建议优先处理 P0。

---

## 一、总体评价

| 维度 | 评分 | 说明 |
|------|------|------|
| 架构分层 | ★★★★☆ | Data / Services / ViewModels / Views 边界干净，无外部依赖（直接链系统 libsqlite3） |
| 注释质量 | ★★★★★ | 大量「为什么这么做」的决策注释，甚至记录了踩过的坑，非常难得 |
| 数据建模 | ★★★★☆ | 元数据与文件彻底分离，符合产品第一原则；表结构合理 |
| 并发正确性 | ★★☆☆☆ | 全部依赖人工保证，Swift 6 严格并发被 `swiftLanguageModes: [.v5]` 规避 |
| UI 性能 | ★★☆☆☆ | 有多处 O(n²) 重绘路径，数据量大时会卡 |
| 国际化 | ★★★☆☆ | 框架完整，但视图层遗漏较多硬编码中文 |
| 测试覆盖 | ★★★☆☆ | 覆盖数据库/解析/过滤/折叠，但缺关键回归用例（见 P0-3） |

---

## 二、P0 — 严重问题（建议立即修）

### P0-1 `hdiutil attach` 缺少 `-readonly`，与产品第一原则冲突

**位置**：`Sources/DMGLibrary/Services/DiskImageService.swift:17-24`

```swift
process.arguments = [
    "attach", imageURL.path,
    "-nobrowse", "-noautoopen", "-mountrandom", mountRoot, "-plist"
]
```

**问题**：README 与关于页都承诺「原始 DMG 永不被重命名、移动或修改」，但 `hdiutil attach` 默认以**读写**方式挂载可写镜像（UDRW 等未压缩格式的 DMG）。挂载本身就可能写回卷元数据、更新文件的 mtime/btime，甚至在没有 `-noautofsck` 时触发文件系统检查。

对于常见下载来的只读压缩镜像（UDZO）不会出问题，所以这个坑一直没暴露——但它恰恰会在用户最不希望出事的地方出事。

**修复**：

```swift
process.arguments = [
    "attach", imageURL.path,
    "-readonly",      // 强制只读挂载：绝不写回原始镜像
    "-nobrowse", "-noautoopen", "-mountrandom", mountRoot, "-plist"
]
```

> 注意：`installApp` 走的是同一条挂载路径，安装是「从挂载点拷出」，只读挂载完全够用。

---

### P0-2 重新解析会覆盖用户自定义名称

**位置**：`Sources/DMGLibrary/ViewModels/LibraryStore.swift:393-395`

```swift
if let appName = result.appInfo?.name, !appName.isEmpty {
    item.displayName = appName      // ← 无条件覆盖
}
```

**矛盾点**：`DMGInspectionService.apply()`（`DMGInspectionService.swift:67-70`）特意写了保护逻辑：

```swift
// 首次解析时才用 App 名回填显示名，避免覆盖用户改名
if item.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
    item.displayName = appInfo.name
}
```

但 `parseOne` 紧接着无条件覆盖，把上面的保护彻底作废。更糟的是 `addPlaceholder`（:343）在导入时就把 `displayName` 设成了 `guessedAppName`（非空），所以 `apply` 里的空判断**永远不成立**。

**影响**：用户把 `xxx_2.4.1_arm64.dmg` 改成「Clash Dashboard」并写了备注，点一次「重新解析」（或启动自动扫库触发），名称就被打回原形。这直接摧毁产品的核心价值主张——「文件不动，信息由你定义」。

**修复**：用一个「用户是否手动改过」的标记来区分，而不是靠空字符串猜：

```swift
// DMGItem 增加字段（Schema 对应加列 display_name_is_custom INTEGER DEFAULT 0）
if !item.displayNameIsCustom, let appName = result.appInfo?.name, !appName.isEmpty {
    item.displayName = appName
}
```
并在 DetailView 的 `scheduleSave` 保存 displayName 时置 `displayNameIsCustom = true`。

---

### P0-3 收藏的旧版本在「收藏」列表里完全不可见 ✅ 已实测复现

**位置**：`Sources/DMGLibrary/ViewModels/LibraryFiltering.swift:52-56` + `:107-126`

```swift
private func computeDisplayedItems() -> [DMGItem] {
    guard shouldCollapseVersions else { return filteredItems }
    let groups = versionGroups
    return filteredItems.filter { groups[$0.groupingKey]?.first?.id == $0.id }
}
```

**根因**：`versionGroups`（代表项选取）基于**全量 `items`**，`isPreferredOver` 只比较版本号 / 存在性 / 创建时间，**完全不考虑 favorite**。而 `displayedItems` 拿全量组的代表项去过滤**子集**，一旦代表项不在子集里，整组就一条都不剩。

**实测**（临时探针用例，验证后已删除）：

```
场景：Chrome 139（未收藏，版本高 → 代表项）+ Chrome 138（已收藏）
store.selection = .smart(.favorites)
  filteredItems.count  == 1   // 旧版本被正确过滤出来
  displayedItems.count == 0   // ← 但列表渲染为空
```

`XCTAssertEqual failed: ("0") is not equal to ("1")`

**用户视角**：我收藏了一个旧版本 DMG，点「收藏」，列表空空如也——数据"消失"了。

**同类影响**：所有会让「组内代表项落选」的过滤都中招——按标签筛选、按分类筛选、按架构筛选、搜索。

**修复**：代表项必须在**过滤后的集合内**选取，而不是先在全局选好再过滤：

```swift
private func computeDisplayedItems() -> [DMGItem] {
    guard shouldCollapseVersions else { return filteredItems }
    var bestIDByKey: [String: Int64] = [:]
    var bestItemByKey: [String: DMGItem] = [:]
    for item in filteredItems {
        let key = item.groupingKey
        if let best = bestItemByKey[key], !isPreferredOver(item, best) { continue }
        bestItemByKey[key] = item
        bestIDByKey[key] = item.id
    }
    return filteredItems.filter { bestIDByKey[$0.groupingKey] == $0.id }
}
```

**顺带补测试**（`Tests/DMGLibraryTests/LibraryStoreTests.swift`）：收藏旧版本后 `displayedItems` 应可见。这个 case 缺失正是缺陷溜进生产的原因。

---

### P0-4 详情面板的草稿数据与 Store 脱节，会回写陈旧数据

**位置**：`Sources/DMGLibrary/Views/DetailView.swift:58, 74-77, 583-587`

```swift
@State private var draft: DMGItem
init(item: DMGItem) {
    self.item = item
    _draft = State(initialValue: item)   // 只在初始化时快照一次
}
```

`.id(item.id)`（:14）只在**切换条目**时重建编辑器。后台任务更新 store 后（`parseOne` 改 displayName、`refreshInstallStatus` 改 installedVersion），`draft` 不会同步。

**影响**：用户在详情里改一个标签 → `saveMetadata(draft)` → 把陈旧的 `displayName` 一起写回数据库，**悄悄回滚了后台刚更新的结果**。两个 bug（P0-2 与 P0-4）叠加时表现为：重新解析后详情显示旧名字，用户一编辑，旧名字被固化进库。

**修复**：检测外部变更并同步 draft（保留用户正在编辑的字段），或改用「字段级草稿」只暂存 note / newTag 这类纯输入态，其余直接读 `item`。

```swift
.onChange(of: item.updatedAt) {   // item 被外部更新时重建草稿
    if !hasUnsavedEdits { draft = item }
}
```

---

## 三、P1 — 重要问题

### P1-1 数据库备份在 WAL 模式下不可靠

**位置**：`Sources/DMGLibrary/Data/AppPaths.swift:30-40`

```swift
try? FileManager.default.copyItem(at: database, to: target)
```

只复制主库文件，**没有复制 `-wal`**。若上次异常退出，WAL 中尚有未 checkpoint 的事务，复制出来的库既丢数据又可能处于不一致状态。而设置页（`settings.backup.footer`）明确向用户承诺「数据库使用 WAL 模式，崩溃也不会丢备注」——**备份恰恰在最需要它的场景下失效**。

**修复**（SQLite 3.27+，macOS 自带版本满足）：

```swift
try database.execute("VACUUM INTO '\(escapedTargetPath)';")
```
或在 Database 里封装 `sqlite3_backup_init/step/finish`。

---

### P1-2 2 秒轮询循环无法被取消

**位置**：`Sources/DMGLibrary/Views/ContentView.swift:100-105`

```swift
Task {                                   // ← 非结构化 Task，不继承 .task 的取消
    while !Task.isCancelled {
        store.refreshPresence()
        try? await Task.sleep(for: .seconds(2))
    }
}
```

`.task` 的结构化取消**不会**传播到这个非结构化 Task。窗口关闭后循环继续运行：每 2 秒对全部条目 `FileManager.fileExists`（O(n) 次 stat），并在 presence 变化时触发 `invalidateDerivedState()` → 全量过滤 + 排序。多开窗口会线性叠加。

**修复**：删掉外层 `Task {}`，让循环直接跑在 `.task` 的结构化上下文里。同时 `refreshPresence` 应放到后台线程做 stat，只把结果回主线程。

---

### P1-3 SHA-256 读取错误被静默当作文件结束

**位置**：`Sources/DMGLibrary/Services/FileFacts.swift:36-42`

```swift
while autoreleasepool(invoking: {
    if let chunk = try? handle.read(upToCount: bufferSize), !chunk.isEmpty {
        hasher.update(data: chunk); return true
    }
    return false                          // ← 读失败与 EOF 走同一条路径
}) { }
```

IO 错误 / 权限问题会让 `try?` 返回 nil，循环当作 EOF 正常结束，**返回一个截断文件的哈希**。这个错误值会被写入数据库，污染重复检测与失联重连（SHA 是最强匹配依据）。

**修复**：

```swift
while true {
    let chunk = try handle.read(upToCount: bufferSize)   // 让错误真的抛出去
    if chunk.isEmpty { break }
    hasher.update(data: chunk)
}
```

---

### P1-4 安装 App 先废纸篓后复制，且阻塞主线程

**位置**：`Sources/DMGLibrary/ViewModels/LibraryStore.swift:735-749`

```swift
if FileManager.default.fileExists(atPath: destination.path) {
    try FileManager.default.trashItem(at: destination, resultingItemURL: nil)  // 先删旧
}
try FileManager.default.copyItem(at: appURL, to: destination)                 // 后拷新
```

- **非原子**：复制中途失败（磁盘满 / 权限），用户原来的 App 已在废纸篓。建议先拷到临时名，再用 `FileManager.replaceItemAt(_:withItemAt:)` 原子替换。
- **主线程阻塞**：`installApp` 是 `@MainActor`，其中 `DiskImageService.attach`（:737）是同步 hdiutil 调用，耗时 1~3 秒。同文件的 `mount()`（:711）就正确用了 `Task.detached`，这里不一致。建议把 attach + copy 整体挪到后台。

---

### P1-5 IconStore 缓存清理用了错误的 key

**位置**：`Sources/DMGLibrary/Services/IconStore.swift:95-100`

```swift
masterCache.removeObject(forKey: filename as NSString)   // ✅ masterCache 的 key 就是 filename
cache.removeObject(forKey: filename as NSString)         // ❌ cache 的 key 是 "filename#像素尺寸"
```

成品缓存条目永远删不掉，删除条目后缩略图仍留在内存（磁盘文件已删，属脏缓存）。

**修复**：删除时按实际 key 枚举清理，或记录该文件已生成过的尺寸集合。

---

### P1-6 删除操作无二次确认

**位置**：`Sources/DMGLibrary/Views/ItemListView.swift:66-69`（Delete 键）与 `:117-121`（右键菜单）

```swift
.onDeleteCommand {
    let ids = Set(store.selectedItemID.map { [$0] } ?? [])
    if !ids.isEmpty { store.delete(ids: ids, moveToTrash: false) }   // 直接删
}
```

按一下 Delete 键，条目的名称 / 备注 / 标签 / 分类全部消失，**无确认、无撤销**。主窗口的批量删除走 `confirmationDialog`，但这两条路径绕过了。用户辛苦维护的「认知」数据一次误触就没了。

**修复**：这两处也走 confirmationDialog，或提供 Undo（`UndoManager`）。

---

## 四、P2 — 中等（性能 / 一致性 / 可维护性）

| # | 问题 | 位置 | 说明 |
|---|------|------|------|
| 2-1 | 侧边栏计数 O(n²) | `SidebarView.swift:18-19, 38-39, 61` | 每个条目 `count(for:)` 调**两次**，每个标签调一次，每次全量 filter。1000 条目 × 50 标签 ≈ 每次重绘 10 万次比较。应随 items 变化缓存一次 |
| 2-2 | 同步 DB IO 跑在主线程 | `LibraryStore.swift:334-361` | `addPlaceholder` 标记了 `async` 但内部无挂起点，`await` 不会让出主线程。导入 500 个文件时主线程被同步 insert 占满 |
| 2-3 | 详情页仍在 body 里 stat 磁盘 | `DetailView.swift:95` `if !item.exists` | 项目专门做了 `presence` 快照解决此问题（`StatusBadge` 用了），详情页却漏了——既频繁 I/O，又可能与列表的失联状态不同步 |
| 2-4 | ByteCountFormatter 反复创建 | `Formatters.swift:32-38` | 每行列表、每个详情都新建一个 formatter，应为 `static let` |
| 2-5 | LazyVStack 被破坏 | `ItemListView.swift:31` | `Array(store.displayedItems.enumerated())` 先构建完整数组，懒加载失效 |
| 2-6 | isImporting 竞态 | `LibraryStore.swift:421` + `:288` | `scanFolder` 检查 `isImporting` 后有 `await Task.detached` 挂起点，`importFiles` 里再检查一次。启动自动扫描与手动导入并发时两者都可能通过 |
| 2-7 | i18n 遗漏 | `ItemListView.swift:76-121`、`ItemGridView.swift:227-229`、`DetailView.swift:252, 424`、`Components.swift:193` | 整个右键菜单（7 项）、「解析失败」「关闭」「删除分类」「共 N 个版本」全是硬编码中文。英文用户界面会中英混排 |
| 2-8 | SearchCache 无界增长 | `LibraryFiltering.swift:324-343` | 以 `item.id` 为 key 的全局字典，删除条目时不清理，长期运行缓慢泄漏 |
| 2-9 | Schema 无真实迁移路径 | `Schema.swift:5-87` | `currentVersion = 2`，但 `migrate` 只有 `CREATE TABLE IF NOT EXISTS`。新增表侥幸能补建，改列则老库不会升级 |
| 2-10 | update() 全量覆盖导致读写竞态 | `ItemRepository.swift:63-68` | UPDATE 覆盖全部 27 列。后台 `computeMissingHashes` / `refreshInstallStatus` 用 items 快照写回，期间用户编辑备注会被回滚 |
| 2-11 | 后台线程调用 NSWorkspace | `InstalledAppService.swift:63` | `urlForApplication` 经 `resolveInstallStatus` 的 `Task.detached` 在后台线程执行，NSWorkspace 非线程安全，可能触发 LaunchServices 线程违规 |
| 2-12 | Mach-O 常量命名误导 | `ArchitectureDetector.swift:9-12` | `fatMagicBE` 等是「文件中大端存储 magic 的整型值」，小端机器上需 `byteSwapped` 才能匹配。当前靠 default 分支兜底才正确，很容易被误"优化"掉 |
| 2-13 | 分类关键词过泛 | `DMGScanner.swift:46, 59` | `"code"` 命中 decode、`"dev"` 命中 Devonthink、`"java"`/`"git"`/`"工具"` 命中面过宽 |
| 2-14 | 多窗口重复启动任务 | `ContentView.swift:92-106` | WindowGroup 支持多开，每个窗口都跑 `refreshFileStatus` + `refreshInstallStatus` + 2 秒轮询 |
| 2-15 | `update()` 列名与绑定靠约定对齐 | `ItemRepository.swift:42-49` vs `DMGItem.insertBindings()` | 27 列与 27 个绑定值分处两地，编译期无保障，加字段时极易漏改 |

---

## 五、值得肯定的设计

这些是项目的资产，重构时请保留：

1. **`presence` 存在性快照**（`LibraryStore.swift:32-34, 619-625`）——`exists` 是 computed 属性不触发 Observation，用快照主动推变化，这个洞察很到位，且注释把原因写清楚了。
2. **统一的派生缓存失效点** `invalidateDerivedState()`（`LibraryStore.swift:99-106`）——filteredItems / displayedItems / versionGroups / duplicateGroups 一处失效，避免了缓存不一致。
3. **IconStore 的三级优化**（`IconStore.swift`）——主图/成品二级缓存 + 后台解码 + `premultiplied` 位图上下文降采样。注释解释了「为什么半透明边缘缩放会渗色边」，专业水平很高。
4. **版本折叠 vs 重复文件/失联的区别对待**（`shouldCollapseVersions`）——理解到这两个列表折叠了就自相矛盾，产品感觉很好。
5. **失联重连的三级递进**（`FileLocator`）——文件名 → 大小 → SHA-256，置信度分级，工程上很扎实。
6. **零外部依赖**——直接链系统 libsqlite3，自建 CSQLite system target，产物干净。
7. **注释文化**——大量记录了「为什么」和「踩过什么坑」（如 NavigationSplitView 的约束冲突、WindowChromeFix 的顶棚方案），这在同类项目里罕见。

---

## 六、建议修复顺序

| 顺序 | 项 | 预估工作量 | 理由 |
|------|-----|-----------|------|
| 1 | P0-1 加 `-readonly` | 1 行 | 一行改动，守住产品第一原则 |
| 2 | P0-3 折叠逻辑 + 补测试 | 小 | 已复现，用户可见的功能缺陷 |
| 3 | P0-2 + P0-4 用户改名保护 | 中 | 两个 bug 同源，一起修 |
| 4 | P1-3 SHA 静默错误 | 1 处 | 会污染数据库，越早越好 |
| 5 | P1-1 备份改用 `VACUUM INTO` | 小 | 承诺与实现不符 |
| 6 | P1-2 轮询循环可取消 | 小 | 关窗口后仍在跑 |
| 7 | P1-6 删除加确认 | 小 | 防止用户丢数据 |
| 8 | P2-1 / 2-2 / 2-3 性能三件套 | 中 | 数据量上来后体感明显 |
| 9 | P2-7 i18n 补齐 | 中 | 双语功能的完整性 |
| 10 | 其余 P2 | — | 排进迭代 |

---

## 附：审查方法

- 通读全部 32 个 Swift 源文件（7,318 行）+ Package.swift / build.sh / Info.plist / 5 个测试文件
- `swift build -c debug`：0 错误 0 警告
- `swift test`：29 个测试全部通过
- 对 P0-3 编写临时探针用例实测复现，验证后已删除，工作区保持干净（`git status` 无变更）
