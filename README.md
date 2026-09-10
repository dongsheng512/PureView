# PureView

macOS 原生图片查看器 · Swift 6 + SwiftUI(混合 AppKit) · 零第三方依赖 · 支持 61 种格式

> `PureView` 是 Pictool 的应用显示名（Bundle 仍为 `Pictool`），主打 **ApolloOne 式文件夹快翻 + 完整 EXIF + 顺手裁切 + 正经打印** 的 Mac 原生体验。

![macOS 14+](https://img.shields.io/badge/macOS-14%2B-blue) ![Swift 6](https://img.shields.io/badge/Swift-6-orange) ![License MIT](https://img.shields.io/badge/license-MIT-green)

**下载：** [Releases](https://github.com/dongsheng512/PureView/releases/latest)（macOS 14+）。源码自行构建见下方。

## ✨ 亮点

- **文件夹快翻**：多根侧栏 + 缩略图网格 + 触控板横滑切图，1000 张目标内存 < 500MB
- **完整 EXIF**：右侧信息抽屉（文件 / 图像 / 拍摄 / GPS），可折叠、一键复制
- **统一编辑**：裁切、文字、画笔（实线/荧光）、形状（矩形/椭圆/直线/箭头）、马赛克、橡皮同一工具条；导出 PNG/JPEG/HEIC/TIFF，默认可另存
- **原生体验**：磨砂侧栏、自绘红绿灯、可拖中线、正经打印（`NSPrintOperation`）
- **格式广度**：ImageIO 原生 61 种可解码（含 HEIC / WebP / AVIF / JXL / 全系 RAW）
- **图标**：深色渐变底 + 白色几何雪山 + 暖橙日（矢量绘制，任意尺寸锐利）

## 功能

- **文件夹浏览**：`NSOpenPanel` 多根项目侧栏 + 文件夹树懒加载 + `UTType.image` + `localizedStandardCompare` 自然排序；最近打开的文件夹（文件菜单 + 欢迎页，最多 8 条）
- **缩略图网格**：边栏下半区 `LazyVGrid` 自适应，`CGImageSourceCreateThumbnailAtIndex` 降采样 + `NSCache(900/80MB)` + 合并重复请求，当前项高亮并自动滚动跟随
- **流畅缩放**：`NSScrollView+NSImageView` 层托管 `CALayer(contents)`，触控板捏合 / `⌘/⌥+滚轮` 锚点缩放 / 拖拽平移 / 双击 `适配↔100%` / 横向主导滑动切图；大图按视口 `×2` 降采样，超阈值自动加载全尺寸无缝替换
- **图片信息**：`CGImageSourceCopyPropertiesAtIndex` 一站式 EXIF/TIFF/IPTC/GPS/色彩/位深/DPI/帧数 + 文件信息，`Inspector` 可折叠 + 一键复制
- **简单裁切**：8 手柄选区 + `自由/1:1/4:3/3:4/16:9/9:16` + 三分线 + 实时像素读数；`CGImage.cropping(to:)` 纯函数换算（单测覆盖），导出 `PNG/JPEG/HEIC/TIFF` 并尽量保留 EXIF
- **统一编辑**：预览式单行工具条（`C` 裁切 / `D` 标记），**文字**（连续字号,选中框角柄拖拽改字号）/ **画笔**（样式 chip:实线/荧光半透明）/ **马赛克·模糊**（笔迹蒙版）/ **形状**（矩形·椭圆·直线·箭头）/ **橡皮** / 裁切同一编辑器；画布缩放平移（捏合·⌘滚轮以指针为锚 `25%–800%`,滚轮/空格拖拽平移,底部状态栏百分比下拉,⌘0 适应）；方向键微调、右键菜单、整行撤销、会话级标注缓存；导出面板（格式/位置信息/水印实时预览）+ 分裂菜单覆盖原图（同格式源）,标记默认不写回原图
- **打印**：`NSPrintOperation` + `per-job PrintInfo(copy)` + `clip` 分页 + 零边距 + `fitScale` 自动横竖
- **格式广度**：ImageIO 原生 61 种可解码（HEIC/HEIF/AVIF/WebP/JXL/PSD/RAW 全系 CR2/NEF/ARW/RAF/RW2/ORF/DNG…）· 21 种可编码，`WebP/AVIF 只解不编` 已约束
- **交互**：`←→` 切图/`0 适配`/`1 实际`/`⌘=/⌘-` 缩放/`I 信息`/`C 裁切`/`F 纯净`/`⌘R 刷新`/`⌃⌘S 侧栏`，支持文件/文件夹拖入、外部用图定位

## 快捷键

| 按键 | 功能 |
|---|---|
| `⌘O` | 打开文件夹 |
| `← / →` | 上一张 / 下一张（首尾循环） |
| `0` / `1` | 适配窗口 / 实际大小 |
| `⌘=` / `⌘-` | 放大 / 缩小（光标为锚点） |
| `I` | 信息面板 |
| `F` / `Esc` | 只看图（沉浸）/ 退出 |
| `C` | 编辑（裁切工具） |
| `D` | 编辑（文字工具） |
| `T` / `B` / `M` / `E` | 编辑中切换 文字/画笔/马赛克/橡皮 |
| `⌘0` / `⌘=` / `⌘-` | 编辑画布 适应窗口 / 放大 / 缩小 |
| `⌘Z` / `⇧⌘Z` | 编辑中 撤销 / 重做 |
| `⌘⏎` | 编辑中打开导出面板 |
| `⌘P` | 打印 |
| `⌃⌘S` / `拖中线` | 显/隐侧栏 / 拖动调节 `180–400` |
| `⌘R` | 刷新当前文件夹 |

## 构建与运行

预编译包：见 [GitHub Releases](https://github.com/dongsheng512/PureView/releases/latest)。

```bash
./build.sh            # release 构建 + 组装 PureView.app（ad-hoc 签名）
open build/PureView.app

swift build           # debug 构建
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test   # 单元测试
```

> `XCTest` 不随 CommandLineTools 提供，需 `DEVELOPER_DIR` 指向完整 Xcode。要求 **macOS 14+ / Xcode 16+**。

## 结构

```
Sources/Pictool/
├── PictoolApp.swift              # @main + WindowGroup(hiddenTitleBar) + 菜单
├── Models/
│   ├── CanvasBackground.swift    # 画布背景偏好（UserDefaults）
│   ├── ImageFile.swift           # UTType 识别与自然排序
│   ├── FolderStore.swift         # 多根/选区/隐藏/LRU/预取（@Observable, MainActor）
│   ├── MarkupAnnotation.swift    # 标记图元 + MarkPalette + MarkupGeometry
│   ├── AnnotationStore.swift     # 进程内标记缓存
│   └── ThumbnailProvider.swift   # 缩略图 NSCache + 合并请求 + 精确计费
├── Views/
│   ├── MainContentView.swift     # 三栏布局 + 可拖中线 + 纯净层
│   ├── PureHeader.swift          # 32pt 自绘顶栏 + 分段磨砂 + 红绿灯
│   ├── ImageViewCanvas.swift     # NSScrollView+NSImageView 画布 + 动图
│   ├── SidebarView.swift         # 文件夹树 + 磨砂材质
│   ├── ThumbnailGridView.swift   # 自适应网格 + 虚线空态
│   ├── EditView.swift            # 统一编辑器（预览式工具条）
│   ├── CropView.swift            # 裁切画布 + 兼容入口
│   ├── MarkupView.swift          # 标记兼容入口
│   ├── InfoInspector.swift       # 信息面板
│   └── SettingsView.swift        # 设置
└── Services/
    ├── ImageLoader.swift         # 降采样/全尺寸解码 + DisplayImageCache(250MB)
    ├── CropService.swift         # 纯函数坐标换算 + 编码保留 EXIF
    ├── AnnotationRenderer.swift  # 标记预览/导出同一绘制
    ├── MarkupService.swift       # 标记烙印导出
    ├── WatermarkService.swift    # 标记导出水印
    ├── MetadataService.swift     # 格式化
    ├── ZoomMath.swift            # 锚点缩放/像素对齐（单测）
    ├── PrintService.swift        # 打印
    └── L10n.swift
Tests/PictoolTests/               # CropMath / MarkupGeometry / WatermarkLayout 等
```

## 许可证

MIT · 零第三方依赖（SVG/JXL 等矢量/高画质为可选二期）

> GPL-3.0 项目 `FlowVision/iMonet/nomacs/qView/Art-Book` 禁止参考；可参考 MIT `imageviewer5/Binder/oculante`
