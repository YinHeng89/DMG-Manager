
# DMG Manager 产品方案

## 一、产品定位

### 产品名称

暂定：

**DMG Manager**

也可以考虑：

* DMG Library
* DMG Vault
* DMG Shelf
* DMG Catalog
* InstallBox
* AppShelf

我个人比较推荐 **DMG Library**。

因为这个产品本质上不是「帮你安装 DMG」，而是：

> **建立属于自己的 Mac 软件安装包资料库。**

---

# 二、核心理念

传统情况下，用户管理 DMG 是这样的：

```text
Downloads
│
├── Chrome.dmg
├── Chrome-139.dmg
├── Cursor.dmg
├── Cursor-1.5.dmg
├── xxx.dmg
├── abc.dmg
├── 微信.dmg
├── 微信.dmg
├── old.dmg
└── ?????.dmg
```

最大的问题不是文件多，而是：

### 用户不知道这个文件是什么。

例如：

```text
xxx_2.4.1_arm64.dmg
```

实际上可能是：

> 某个网络工具 ARM64 版本

但文件名本身没有任何信息。

所以我们的产品核心就是：

### **文件系统负责存文件，DMG Manager 负责管理“认知”。**

---

# 三、最重要的设计原则

## 1. 永远不修改原始 DMG

这是整个产品最重要的原则。

例如：

```text
真实文件：

~/Downloads/xxx_2.4.1_arm64.dmg
```

软件里面：

```text
显示名称：
Clash Dashboard

备注：
我的主力代理管理工具
ARM64 版本
```

**不会执行：**

```text
mv xxx_2.4.1_arm64.dmg Clash Dashboard.dmg
```

也不会往 DMG 里面写任何东西。

---

# 四、元数据与文件彻底分离

建议采用：

```text
DMG 文件
    │
    └── 文件系统
         │
         ├── 原始文件名
         ├── 路径
         ├── 大小
         ├── 修改时间
         └── 文件本身
             
DMG Manager Database
    │
    └── 元数据
         ├── 自定义名称
         ├── 备注
         ├── 标签
         ├── 分类
         ├── 收藏
         ├── 软件名称
         ├── 版本
         ├── 架构
         ├── 开发者
         ├── 添加时间
         └── 自定义信息
```

这样最大的好处就是：

**用户怎么管理都不会污染原始文件。**

---

# 五、核心功能

## ① DMG 导入

支持：

### 拖拽

直接把：

```text
xxx.dmg
```

拖进软件。

---

### Finder → 打开方式

支持：

```text
右键
→ 打开方式
→ DMG Manager
```

---

### 文件夹扫描

例如：

```text
扫描 ~/Downloads
```

自动发现：

```text
*.dmg
```

然后建立索引。

> **启动自动扫描**：应用启动后会在后台扫描所有「监控目录」（设置里添加的文件夹），
> 不阻塞首屏；扫描结果按路径与数据库比对，**仅新增真正的新 DMG**（已入库的跳过），
> 并在中间列顶部弹出「本次扫描新增 N 个」的提示，几秒后自动消失。
> 没有监控目录时不扫描。

---

### 批量导入

支持：

```text
选择 50 个 DMG
↓
批量导入
↓
自动解析
```

---

# 六、自动解析 DMG

这是这个产品非常重要的一个功能。

用户添加：

```text
Chrome_139.0.7258_arm64.dmg
```

软件自动读取 DMG。

### 自动提取：

```text
文件名称
文件大小
创建时间
修改时间
文件路径
```

然后挂载 DMG，读取里面的 App。

例如：

```text
Google Chrome.app
```

进一步读取：

```text
CFBundleDisplayName
CFBundleShortVersionString
CFBundleVersion
CFBundleIdentifier
CFBundleSupportedPlatforms
```

最终自动生成：

```text
Google Chrome

版本：
139.0.7258.76

架构：
Apple Silicon

Bundle ID：
com.google.Chrome
```

---

# 七、自动识别架构

这个功能我建议一定做。

例如 DMG：

```text
Chrome Intel.dmg
Chrome ARM64.dmg
Chrome Universal.dmg
```

软件自动识别：

### Intel

```text
x86_64
```

### Apple Silicon

```text
arm64
```

### Universal

```text
arm64 + x86_64
```

UI 可以显示：

```text
 Apple Silicon
```

或者：

```text
Intel
```

或者：

```text
Universal
```

---

# 八、自定义名称

这是你的核心需求之一。

例如：

```text
实际文件：

Install_MarsEdit_5.8.3.dmg
```

软件中：

```text
MarsEdit
```

注意：

### 只是显示名称改变。

真实文件依然：

```text
Install_MarsEdit_5.8.3.dmg
```

---

# 九、备注系统

每一个 DMG 都有独立备注。

例如：

> 公司电脑使用的版本，暂时不要升级。

或者：

> 这是最后一个支持 macOS 13 的版本。

或者：

> M5 测试过可以正常运行。

甚至可以支持 Markdown：

```markdown
## 使用说明

这是旧版本。

### 注意

不要升级到最新版。

### 测试情况

- M5 ✅
- macOS 26 ✅
- Intel ❌
```

---

# 十、标签系统

标签比分类更加灵活。

例如：

```text
#浏览器
#开发
#旧版本
#ARM64
#工作
#常用
#游戏
#代理
```

一个 DMG 可以拥有多个标签：

```text
Google Chrome

[浏览器] [ARM64] [常用]
```

---

# 十一、分类

左侧可以提供：

```text
全部
收藏
最近添加
最近使用

软件
├── 浏览器
├── 开发工具
├── 网络工具
├── 多媒体
├── 游戏
├── 办公
└── 系统工具

其他
├── 驱动
├── 系统
├── 工具
└── 未分类
```

分类和标签不要混为一谈。

### 分类

代表：

> **它是什么**

### 标签

代表：

> **它有什么属性**

---

# 十二、收藏

支持：

```text
⭐ 收藏
```

例如：

```text
Cursor
Raycast
Chrome
IINA
```

可以直接进入：

```text
⭐ 收藏
```

---

# 十三、搜索

搜索应该是整个产品非常核心的功能。

支持：

```text
⌘ K
```

打开快速搜索。

可以搜索：

```text
名称
原始文件名
备注
标签
软件名称
版本
Bundle ID
开发者
路径
```

例如：

```text
输入：

chrome
```

找到：

```text
Google Chrome
Chromium
Chrome Beta
Chrome Dev
```

---

# 十四、高级筛选

例如：

```text
架构：
Apple Silicon

版本：
> 100

大小：
< 500 MB

标签：
开发

分类：
浏览器

状态：
已安装
```

甚至：

```text
Apple Silicon + 浏览器 + 未安装
```

---

# 十五、DMG 内部预览

用户选中一个 DMG 后，右侧显示：

```text
┌──────────────────────────────┐
│                              │
│          Chrome 图标         │
│                              │
│       Google Chrome          │
│       139.0.7258.76          │
│                              │
├──────────────────────────────┤
│ 原始文件                      │
│ Chrome_139.0.7258_arm64.dmg │
│                              │
│ 大小                         │
│ 182.4 MB                     │
│                              │
│ 架构                         │
│ Apple Silicon                │
│                              │
│ 开发者                       │
│ Google LLC                   │
└──────────────────────────────┘
```

---

# 十六、DMG 内容浏览

可以提供：

> **查看 DMG 内容**

但不一定真的让用户修改。

例如：

```text
Chrome.dmg
│
├── Google Chrome.app
├── Applications
├── README.txt
└── .background
```

点击 App：

```text
Google Chrome.app
```

显示：

```text
版本
Bundle ID
架构
签名
开发者
最低系统版本
```

---

# 十七、安装状态

这个功能也非常有价值。

例如：

```text
Google Chrome

版本：139.0.7258

DMG：
139.0.7258

当前系统：
139.0.7258

状态：
✓ 已安装
```

如果：

```text
DMG：

Google Chrome 138

系统：

Google Chrome 139
```

显示：

```text
↓ 旧版本
```

甚至：

```text
⚠ 当前安装版本更高
```

---

# 十八、版本库

这会让这个软件从普通文件管理器真正变成：

> **软件安装包资料库。**

例如：

```text
Google Chrome
│
├── 139.0.7258
│   └── Chrome_139_arm64.dmg
│
├── 138.0.7204
│   └── Chrome_138_arm64.dmg
│
└── 137.0.7151
    └── Chrome_137_arm64.dmg
```

然后：

```text
Google Chrome
3 个版本

最新：
139.0.7258

已安装：
139.0.7258

历史版本：
138
137
```

这个功能我认为非常值得做。

### 列表只占一行

一个软件在中间列表里**只显示一条**，默认就是最新版本，不会把 139 / 138 / 137 三条全堆上去：

```text
Google Chrome    139.0.7258 · 182 MB · 共 3 个版本
Cursor           1.5.0      · 210 MB
```

旧版本没有消失，只是收进了详情面板的「版本库」：

```text
版本库 · 3 个版本

139.0.7258   最新  当前     Chrome_139.dmg
138.0.7204                Chrome_138.dmg
137.0.7151                Chrome_137.dmg
```

点任意一行就切过去，**头部的名称 / 版本 / 架构 / 安装状态和「安装包信息」整块跟着换成这个版本的数据**——它们本来就是各版本各自独立的记录。

代表项的选取顺序：版本号高 → 文件还在 → 新入库。所以默认看到的一定是最新的那份。

两个例外不折叠：

- **重复文件**：这个列表存在的意义就是把每一份都摆出来，折叠了就没法挑出要删的那份
- **文件失联**：失联的旧版本也要看得见，否则没法重新定位

实现见 `LibraryFiltering` 的 `displayedItems` / `versionGroups`。

---

# 十九、重复 DMG 检测

例如用户导入：

```text
Chrome.dmg
Chrome (1).dmg
Chrome copy.dmg
Chrome_139.dmg
```

软件计算：

```text
SHA-256
```

发现：

```text
Chrome.dmg
Chrome (1).dmg
```

实际上完全一样。

提示：

> **检测到重复文件**

理想交互（尚未实现，见下方「现状」）：

```text
保留
删除重复项
忽略
```

注意：

**删除操作必须明确二次确认。**

### 现状（已实现的部分）

- **检测已落地**：导入后后台补算 SHA-256（`computeMissingHashes`），侧边栏「重复文件」按哈希分组展示，计数取自 `duplicateGroups()`。
- **「重复文件」列表不折叠**：同一份软件的多份拷贝（如 `Chrome.dmg` / `Chrome (1).dmg`）会**逐条列出**——这个列表的存在意义就是把每一份都摆出来供挑选删除，所以不走第十八节的「同软件只显示一条」折叠逻辑。
- **一键清理暂未做**：上面的「保留 / 删除重复项 / 忽略」三选交互目前没有实现，用户仍需手动多选后走通用删除确认（已带二次确认 + 可选移入废纸篓）。
- **算法已优化**：`duplicateGroups()` 加了缓存（侧边栏每次 body 重绘不再重扫全表）；重复筛选从「哈希数组 `flatMap` + `contains`」的 O(n²) 改为 `Set` 查表；版本聚合改为 `groupIndexCache` 一次 O(n) 建索引后全 O(1) 查表。

---

# 二十、文件失联检测

这个非常重要。

比如用户把：

```text
~/Downloads/Chrome.dmg
```

移动到了：

```text
~/Software/Chrome.dmg
```

数据库原来的路径失效。

显示：

```text
⚠ 文件位置已改变
```

然后：

```text
[重新定位]   [自动查找]   [从资料库移除]
```

- **重新定位**：手动选新文件，把这条记录指过去。
- **自动查找**：在「原目录 + 监控目录 + ~/Downloads、~/Desktop、~/Documents、~/Software」里按
  「文件名 → 大小 → SHA-256」逐级匹配，命中即自动重连（无需手动选文件）。
- **从资料库移除**：确认文件确实已不在磁盘（例如自己删掉的旧版本），
  只删掉这条资料库记录（带二次确认，不动磁盘）。

---

# 二十一、智能重新定位

更进一步，可以通过：

```text
文件名
文件大小
SHA-256
```

自动寻找。

例如：

```text
原文件：

Chrome_139.dmg
182 MB
SHA256: xxxxx
```

发现：

```text
/Software/Chrome_139.dmg
```

完全匹配。

直接：

> ✓ 已自动重新连接

用户甚至不需要操作。

---

# 二十二、文件操作

右侧提供：

```text
打开 DMG
挂载 DMG
在 Finder 中显示
复制路径
复制文件
删除 DMG
重新定位
```

以及：

```text
安装 App
```

但是这里可以保持克制。

我们**不把产品做成 EasyDMG**。

EasyDMG 本身的定位是自动挂载、复制 App、卸载和清理 DMG。([GitHub][1])

我们的产品核心仍然是：

> **管理 DMG。**

---

# 二十三、菜单栏快速入口

可以提供一个 Menu Bar：

```text
┌────────────────────────┐
│ 📦 DMG Library         │
├────────────────────────┤
│ 🔍 搜索 DMG            │
│                        │
│ ⭐ 收藏  12            │
│ 📦 全部  128           │
│ 🕘 最近  8             │
│                        │
│ ➕ 添加 DMG             │
│ 📂 扫描文件夹           │
│                        │
│ 打开主窗口              │
└────────────────────────┘
```

---

# 二十四、Quick Look

支持：

```text
Space
```

快速查看 DMG。

最好直接整合 macOS Quick Look。

---

# 二十五、拖拽体验

例如：

```text
Finder
     ↓
拖入 DMG Manager
```

立即：

```text
正在解析……

Chrome.dmg

✓ DMG
✓ App
✓ Version
✓ Architecture
```

然后出现编辑卡片：

```text
显示名称：
[Google Chrome          ]

备注：
[                       ]

标签：
[浏览器] [+]
```

点击：

```text
完成
```

---

# 二十六、数据结构

建议 SQLite。

例如：

```sql
dmg_items
```

核心字段：

```text
id
path
filename
display_name
note
category
favorite

file_size
created_at
modified_at

sha256

app_name
bundle_id
version
build
developer
architecture
minimum_os

installed
installed_version

created_time
updated_time
```

标签：

```text
tags
```

关系：

```text
dmg_tags
```

---

# 二十七、为什么必须数据库

这里有一个非常关键的产品设计。

我们**不能**把备注写进：

```text
DMG 文件名
```

也不建议依赖：

```text
Finder 标签
```

因为：

> Finder 标签只是文件系统元数据，不够表达我们的完整信息模型。

像 TagSpaces 这样的现有工具已经证明「文件 + 标签 + 本地元数据」是一条可行路线，但它是通用文件组织器，而不是针对 DMG 的专用产品。([GitHub][2])

我们需要的是：

```text
DMG
 ↓
独立 Metadata
 ↓
SQLite
```

这样最干净。

---

# 二十八、数据安全

数据库建议：

```text
~/Library/Application Support/DMGLibrary/
```

例如：

```text
database.sqlite
thumbnails/
metadata/
backups/
```

---

## 自动备份

可以保留：

```text
database.sqlite
database.sqlite.backup
```

或者：

```text
每次修改自动写 WAL
```

这样即使软件崩溃，也不会轻易丢失备注。

---

# 二十九、完全本地化

产品应该明确：

> **Local First**

默认：

```text
无账号
无服务器
无云端
无遥测
无联网要求
```

所有数据：

```text
DMG
+
SQLite
```

都在用户自己的 Mac 上。

这也是目前一些开源文件 Catalog 工具强调的方向，例如 Katalog 支持离线建立文件目录、元数据和校验信息，并能在设备离线时继续搜索目录。([GitHub][3])

---

# 三十、未来可以加入 iCloud

但不是第一版。

可以设计成：

```text
本地数据库
      ↓
iCloud Drive
      ↓
Mac A
Mac B
```

不过这里要注意：

**不要同步 DMG 本体。**

只同步：

```text
metadata
database
```

例如：

```text
MacBook Air
        ↕
    iCloud
        ↕
Mac Studio
```

两个设备都能看到：

```text
Google Chrome

备注：
工作电脑使用

标签：
浏览器 / ARM64 / 工作
```

但 DMG 本体是否存在于本机，单独判断。

---

# 三十一、UI 结构

我建议直接采用非常标准的 macOS 三栏结构：

```text
┌─────────────────────────────────────────────────────┐
│ DMG Library              🔍 搜索          ＋ 添加    │
├────────────┬────────────────────┬───────────────────┤
│            │                    │                   │
│ 📦 全部    │  Google Chrome     │   Chrome 图标     │
│ ⭐ 收藏    │  Cursor            │                   │
│ 🕘 最近    │  Raycast           │   Google Chrome   │
│            │  IINA              │   139.0.7258      │
│ 分类       │  Arc               │                   │
│ 浏览器     │                    │   Apple Silicon   │
│ 开发       │                    │   182 MB          │
│ 网络       │                    │                   │
│ 游戏       │                    │   备注            │
│ 工具       │                    │   工作电脑使用     │
│            │                    │                   │
│ 标签       │                    │   [打开] [Finder] │
│ #ARM64     │                    │                   │
│ #旧版本    │                    │                   │
└────────────┴────────────────────┴───────────────────┘
```

---

# 三十二、列表视图

可以切换：

### 图标

```text
┌──────┐ ┌──────┐ ┌──────┐
│ Chrome│ │Cursor│ │ IINA │
│ 139   │ │1.5   │ │1.3   │
└──────┘ └──────┘ └──────┘
```

### 列表

```text
名称        版本       架构        大小       状态
Chrome      139        ARM64       182MB      已安装
Cursor      1.5        Universal   210MB      已安装
IINA        1.3        ARM64       45MB       未安装
```

### 分组

例如：

```text
浏览器

Chrome
Arc
Firefox
```

---

# 三十三、智能状态

每个 DMG 可以显示状态：

```text
✓ 已安装
↓ 旧版本
↑ 新版本
⚠ 文件失联
⚠ 无法解析
◌ 未安装
```

---

# 三十四、未来增强：应用图标

如果 DMG 内有：

```text
xxx.app
```

自动提取：

```text
App Icon
```

因此列表不再是一堆：

```text
📦 xxx.dmg
```

而是：

```text
🌐 Google Chrome
💻 Cursor
🎬 IINA
🎨 Photoshop
🎮 Whisky
```

这会让整个产品的观感提升非常大。

---

# 三十五、未来增强：软件主页

点击：

```text
Google Chrome
```

可以看到：

```text
Google Chrome

139.0.7258
Apple Silicon

────────────────────

安装包

139.0.7258   ✓ 当前
138.0.7204
137.0.7151

────────────────────

备注

工作电脑使用。

────────────────────

标签

浏览器
ARM64
工作
常用
```

这时候它已经非常像一个：

> **个人软件安装包仓库。**

---

# 三十六、未来增强：版本历史

例如：

```text
Chrome

版本历史

139.0.7258    2026-08-20
138.0.7204    2026-07-15
137.0.7151    2026-06-20
136.0.7103    2026-05-12
```

并且每个版本对应一个真实 DMG。

---

# 三十七、未来增强：自动监控 Downloads

可以监控：

```text
~/Downloads
```

发现：

```text
Chrome.dmg
```

自动提示：

> 发现新的 DMG 安装包

```text
Google Chrome
139.0.7258
Apple Silicon

[添加到库] [忽略]
```

甚至可以自动添加。

---

# 三十八、未来增强：智能分类

以后可以根据：

```text
App 名称
Bundle ID
文件名
开发者
```

自动分类：

```text
Chrome
↓
浏览器

Cursor
↓
开发工具

IINA
↓
多媒体

Whisky
↓
游戏工具
```

第一版不需要 AI。

**规则匹配已经够用了。**

---

# 三十九、技术方案

如果是你自己开发，我非常建议：

### macOS 原生

```text
Swift
+
SwiftUI
+
AppKit
+
SQLite / SwiftData
```

原因很简单：

这个产品本质上就是一个：

> **macOS 文件系统工具**

需要大量调用：

```text
NSWorkspace
FileManager
Quick Look
UTType
Disk Arbitration
FSEvents
Security / Code Signing
```

原生实现会比较舒服。

---

# 四十、如果考虑跨平台

如果以后真的想做：

```text
macOS
Windows
Linux
```

那么可以：

```text
Tauri
+
Rust
+
Vue
```

但我认为：

### 第一版不要跨平台。

因为你的核心需求非常 Mac：

```text
DMG
.app
Finder
Quick Look
Apple Silicon
Gatekeeper
Disk Image
```

先做成：

> **Mac 专用 DMG Library**

反而会更漂亮。

---

# 四十一、MVP 第一版

我建议第一版千万不要做太大。

只做这 **10 个功能**：

### P0

1. 添加 DMG
2. 扫描文件夹
3. 自动解析 DMG
4. 自动获取 App 图标
5. 自动获取版本
6. 自动识别 ARM64 / Intel / Universal
7. 自定义显示名称
8. 自定义备注
9. 标签
10. 搜索

再加：

```text
在 Finder 中显示
打开 DMG
挂载 DMG
删除 DMG
收藏
```

这就已经很好用了。

---

# 四十二、V1.1

然后增加：

```text
├── 已安装检测
├── 当前版本比较
├── SHA256
├── 重复文件检测
├── 文件失联检测
├── 自动重新定位
├── 高级筛选
└── 最近添加
```

---

# 四十三、V2

再做：

```text
├── Downloads 自动监控
├── 版本历史
├── 智能分类
├── iCloud 元数据同步
├── 快捷键
├── Menu Bar
├── Quick Look
└── Apple Shortcuts
```

---

# 四十四、和现有软件的区别

目前能找到的产品大致是：

**EasyDMG**

> 解决「DMG 怎么安装」。

[EasyDMG GitHub](https://github.com/jeff-schumann/EasyDMG?utm_source=chatgpt.com)

**Katalog**

> 解决「如何建立磁盘/文件目录」。

[Katalog GitHub](https://github.com/StephaneCouturier/Katalog?utm_source=chatgpt.com)

**TagSpaces**

> 解决「如何给本地文件打标签、写笔记」。

[TagSpaces GitHub](https://github.com/tagspaces/tagspaces?utm_source=chatgpt.com)

而我们这个产品解决的是一个更具体的问题：

> **「我有几十、几百个 DMG，我想把它们当成一个软件安装包库管理。」**

这就是产品的差异化。

---

# 四十五、最终产品一句话

我会把整个产品定义成：

> ### **一个不改变原始文件的 Mac DMG 安装包资料库。**
>
> **自动识别软件、版本和架构，并允许用户用自定义名称、备注、标签和分类管理自己的 DMG 收藏。**

甚至可以进一步形成一句非常好的产品 Slogan：

> **Keep the file. Organize the meaning.**
>
> **文件不动，信息由你定义。**

这个定位我觉得比单纯叫「DMG Manager」更准确。


---

# 四十六、实现状态

上面四十五节是产品方案，这一节记录**代码实际做到了哪一步**。

## 技术选型

| 项目 | 选择 | 理由 |
| --- | --- | --- |
| 语言 | Swift 6 | 直接调用 hdiutil / Security / LaunchServices，无需桥接 |
| 界面 | SwiftUI + AppKit | 三栏 NavigationSplitView、菜单栏、Quick Look 都是原生能力 |
| 数据库 | SQLite（系统自带 libsqlite3） | 零外部依赖，WAL 模式 |
| 依赖 | **无** | 不引入任何三方包，离线可构建 |

按方案第三十九节的建议做 Mac 原生，第一版不跨平台。

## 工程结构

```text
Sources/
├── CSQLite/                  系统 SQLite 的 modulemap 垫片（无三方依赖）
└── DMGLibrary/
    ├── main.swift            SwiftPM 入口
    ├── App/
    │   ├── DMGLibraryApp.swift    窗口 / 菜单栏 / 设置 / 快捷键
    │   └── AppDelegate.swift      Finder「打开方式」的 Apple Event 处理
    ├── Models/
    │   ├── DMGItem.swift          一条记录 + 安装状态推导
    │   └── Enums.swift            架构 / 解析状态 / 智能分组 / 筛选
    ├── Data/
    │   ├── Database.swift         SQLite 薄封装（WAL）
    │   ├── Schema.swift           建表与键值设置
    │   ├── ItemRepository.swift   读写与标签聚合
    │   └── AppPaths.swift         数据目录 + 自动备份
    ├── Services/
    │   ├── DiskImageService.swift      hdiutil 挂载 / 卸载
    │   ├── AppBundleInspector.swift    找 .app、读 Info.plist、读签名
    │   ├── ArchitectureDetector.swift  直接解析 Mach-O / FAT 头
    │   ├── IconStore.swift             icns → PNG，带内存缓存
    │   ├── FileFacts.swift             文件属性 + SHA-256
    │   ├── FileLocator.swift           失联重定位（文件名 → 大小 → 哈希）
    │   ├── InstalledAppService.swift   已安装 App 索引
    │   ├── DMGScanner.swift            文件夹扫描 + 规则分类
    │   └── DMGInspectionService.swift  解析编排
    ├── ViewModels/
    │   ├── LibraryStore.swift      单一数据源（@Observable）
    │   └── LibraryFiltering.swift  搜索 / 筛选 / 排序
    └── Views/                     三栏界面、详情、筛选面板、设置
```

## 功能清单

### P0（第一版，已全部完成）

| # | 功能 | 实现位置 |
| --- | --- | --- |
| 1 | 添加 DMG（拖拽 / 文件选择器 / 批量 / Finder 打开方式） | `ContentView.handleDrop`、`AppDelegate` |
| 2 | 扫描文件夹 | `DMGScanner` + `LibraryStore.scanFolder` |
| 3 | 自动解析 DMG | `DMGInspectionService` |
| 4 | 自动获取 App 图标 | `IconStore`（ImageIO 提取 icns） |
| 5 | 自动获取版本 / Build / Bundle ID / 最低系统 | `AppBundleInspector` |
| 6 | 自动识别 ARM64 / Intel / Universal | `ArchitectureDetector`（读 Mach-O 头，不依赖 `lipo`） |
| 7 | 自定义显示名称 | 详情面板，防抖落库 |
| 8 | 自定义备注（Markdown） | 详情面板，`AttributedString(markdown:)` 渲染 |
| 9 | 标签 | 详情面板 + 侧边栏标签分组 |
| 10 | 搜索（⌘K） | 覆盖名称 / 文件名 / 备注 / 标签 / 版本 / Bundle ID / 路径 |

附加：收藏、分类、在 Finder 中显示、打开 DMG、静默挂载与卸载、复制路径、删除（二次确认 + 可选移入废纸篓）。

### V1.1（已全部完成）

- 已安装检测：扫描 `/Applications`、`~/Applications`，并用 LaunchServices 兜底
- 当前版本比较：`已安装 / 旧版本 / 有更新 / 未安装`
- SHA-256：导入后后台补算，用于重复检测与失联重连
- 重复文件检测：侧边栏「重复文件」按哈希分组
- 文件失联检测：启动自动校验，列表与详情都有警示
- 自动重新定位：文件名 → 大小 → SHA-256 逐级确认，命中即自动重连
- 高级筛选：架构 / 安装状态 / 解析状态 / 分类 / 标签
- 最近添加、最近使用

### V1.2（本次新增，已全部完成）

- **同软件列表折叠**：中间列表按 `groupingKey`（优先 Bundle ID，无则用小写 appName）聚合，每组只显示一条代表项，默认取**最新版本**；旧版本收进详情「版本库」。代表项选取顺序：版本号高 → 文件还在 → 新入库。
  - 实现：`LibraryFiltering.displayedItems` / `versionGroups`。
  - 两个例外**不折叠**：「重复文件」（需逐份挑删）、「文件失联」（需看见旧版本以便重定位）。
- **版本库切换联动**：详情「版本库」列出组内全部成员（最新优先），点击任意版本即切换 `selectedItemID`，标题、版本、架构、安装状态与「安装包信息」整块跟随更新（各版本本就是独立记录）。当前项按 id 判定，不再硬编码第一行。
- **详情操作按钮固定**：包信息界面的操作按钮排从滚动区内移出，固定在「架构 / 状态徽章」一行的正下方，不随下方信息滚动。
- **性能优化**：`groupIndexCache` 一次 O(n) 建索引后 `relatedVersions` / 代表项选取 / 版本计数全 O(1)；`duplicateGroups` 加缓存；重复筛选 O(n²) → `Set`；修复逐行选中态判定曾退化的 O(n²)（改由 `representativeID` 直接查表）。

### V2（未实现，按方案属后续版本）

Downloads 自动监控、完整版本历史时间线、iCloud 元数据同步、Quick Look 预览、Apple Shortcuts。

## 数据安全

```text
~/Library/Application Support/DMGLibrary/
├── database.sqlite        WAL 模式，崩溃不丢备注
├── thumbnails/            从 DMG 提取的 App 图标
└── backups/               每次启动自动快照，保留最近 5 份
```

Local First：无账号、无服务器、无云端、无遥测、无联网要求。

## 构建与运行

```bash
./build.sh            # release 构建并打包到 dist/
./build.sh --debug    # debug 构建
./build.sh --run      # 构建完成后立即启动

swift test --disable-sandbox   # 29 个测试
```

> 当前环境下 SwiftPM 需要关闭沙箱，`build.sh` 已处理。

要求：macOS 14+，Xcode 命令行工具。

## 测试覆盖

- `InspectionTests`：用 `hdiutil create` 造真实 DMG，验证挂载 → 找 App → 读 plist → 架构 → 图标全链路
- `DatabaseTests`：读写、元数据更新不覆盖解析结果、标签聚合、SHA-256
- `LibraryStoreTests`：搜索命中各字段、智能分组、筛选、排序、版本库聚合、失联检测、重新定位、删除；**新增**：列表折叠（`displayedItems` 按组只留代表项）、代表项选取顺序（版本高 → 文件在 → 新入库）、`representativeID` 组判定、`versionCount` 计数、版本库按版本降序。
- `VersionTests`：版本号比较（含预发布段）
