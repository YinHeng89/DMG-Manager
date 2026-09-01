# DMG Library 产品官网

纯静态、零依赖的产品落地页，用于介绍 **DMG Library**（一款本地优先的 macOS DMG 安装包资料库）。

## 文件

- `index.html` — 页面结构（导航 / Hero / 功能 / 隐私 / 下载 / 页脚）
- `styles.css` — 样式（含浅色 / 深色主题变量，跟随系统并支持手动切换）
- `script.js` — 主题切换（记忆到 localStorage）+ 页脚年份

## 本地预览

无需任何构建步骤，任选一种方式：

```bash
# 方式一：直接用浏览器打开
open index.html

# 方式二：起一个本地静态服务器（推荐，避免 file:// 限制）
python3 -m http.server 8080
# 然后访问 http://localhost:8080
```

## 说明

- 文案中英双语以应用内为准；此处官网以中文为主、英文 tagline 点缀。
- 下载按钮指向 `../dist/DMG Library.dmg`（由仓库根目录 `build.sh` 打包生成）。
- 无外部 CDN / 字体依赖，可离线打开。
