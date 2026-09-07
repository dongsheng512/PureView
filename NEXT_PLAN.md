# 后续功能执行规格(给实现 agent)

> 状态:**尚未开工**(整理于 2026-09-07,对照仓库 v0.7.6)。本文期号 **C1–C4 / D 候补**,不要和 `PLAN.md` 的 M0–M6、`MARKUP_PLAN.md` 的 A1–A4、`EDIT_UX_PLAN.md` 的 B0–B4 混用。
> 主线已齐:五项浏览需求(M)、标记 A1–A4、编辑器交互 B0–B4 均已落地。后面不加新主线,只补还差一口气的体验,以及 B 期点名后置的能力。
> 对标交互参考:**macOS 预览(Preview.app)**——只借鉴交互模型,不看它的代码。
> 基线:统一编辑器 `Sources/Pictool/Views/EditView.swift`;浏览态 `FolderStore` / `SidebarView` / `ThumbnailGridView`。
> 版本节奏**由用户决定**:每期合入时同步 `build.sh` 的 `CFBundleShortVersionString` + `README.md`「版本」小节。

---

## 0. 实现 agent 必读(先做完再写代码)

1. 读 `AGENTS.md`、`MARKUP_PLAN.md` 第 2–3 节(冻结坐标系与模型)、`EDIT_UX_PLAN.md` 文档头(B 期 as-built)、本文全文。只做**当前期**,不要把 C2–C4 或 D 候补顺手做了。
2. 许可证红线不变:FlowVision / iMonet / nomacs / qView / Art-Book 均 GPL-3.0,禁止参考;可借鉴思路的 MIT 项目:imageviewer5 / Binder / oculante。
3. 核心**零第三方依赖**。禁止 PencilKit、任何 SPM 包。
4. 部署 macOS 14+,Swift 6,纯 SPM,不建 xcodeproj。
5. 只测纯逻辑,不测 UI。命令:`swift build` / `swift test` / `swift test --filter <TestName>`。
6. 每期结束:`swift test` 全绿 + 版本同步 + `./build.sh` 打包。
7. 注释短、事实、只解释非显然约束;UI 文案中文。
8. 标注数据仍是会话内存(`AnnotationStore`,不落盘)。改 `Annotation.Kind` 时必须同步渲染器、命中测试、选区 bounds 三处。C2 改颜色模型时尤其如此。

---

## 1. 现状与缺口

### 1.1 已经做对的(保持,不要重做)

- 浏览:多根文件夹、缩略图网格、`NSScrollView+NSImageView` 缩放平移、横滑超阈值切图、信息抽屉、打印、偏好(背景/排序/幻灯片)、幻灯片、纯净模式。
- 编辑:裁切 + 文字/画笔/荧光笔/马赛克/橡皮/形状同一工具条;归一化坐标 + `AnnotationRenderer` 双路径;编辑画布缩放平移;文字角柄连续字号;导出分裂菜单 + 水印在导出流。
- 切图入场:新图沿方向 24pt 滑入 + 淡入;触控板横滑 ≥ 55pt 直接切图。0.7.2–0.7.5 的幽灵层/覆盖式/跟手手势**未合入,不要再开**除非用户明确要求。

### 1.2 按用户影响排序的缺口

| # | 缺口 | 影响 | 归属 |
|---|---|---|---|
| 1 | 形状创建后只能移动/删,不能拉对角或改端点 | 编辑器里唯一明显矮于预览.app 的交互 | **C1** |
| 2 | 调色盘只有六色,没有自定义色 | 截图批注对不准品牌色/原色 | **C2** |
| 3 | 冷启动没有最近文件夹;目录增删要 `⌘R` | 查看器还是「打开一次」而不是「接着看」 | **C3** |
| 4 | 隐藏图只能整夹恢复或重启 | 「图丢了」的错觉 | **C4** |

### 1.3 硬顺序

| 期 | 功能 | 依赖 | 可裁剪 |
|---|---|---|---|
| **C1** | 形状手柄重塑 | 无(B2 模型已是 from/to) | 否 |
| **C2** | 自定义颜色(`MarkupColor`) | 无,但改 Kind 签名波及全部工具,单独一期 | 否(不要拆到 C1) |
| **C3** | 最近文件夹 + 当前目录监听 | 无 | 监听可砍、最近文件夹不可砍 |
| **C4** | 隐藏图单张恢复 + 刷新策略 | 无 | 否 |

C1 → C2 → C3 → C4。C3/C4 与编辑器无关,理论可与 C1 并行,但**一次只做一期**。

---

## 2. C1 形状手柄重塑

`EDIT_UX_PLAN.md` §4.7 / §7:「形状手柄重塑(创建后只能移动/删,重塑列后续 C 期)」——本期把它做完。

### 2.1 设计决策(冻结)

- **不改模型**。`.shape(kind:from:to:widthLevel:colorIndex:)` 已经能表达任意对角/端点,只补命中与拖动手柄。
- 矩形 / 椭圆:**8 手柄**(四角 + 四边中点),语义对齐裁切选区。拖角改对角点;拖边只动对应轴。Shift 按住时矩形/椭圆锁宽高比(以对边/对角为锚);未按 Shift 自由拉伸。
- 直线 / 箭头:**2 端点手柄**(from 与 to)。拖哪端改哪端;箭头头始终在 to。
- 命中优先级:**手柄 > 标注体 > 空白**(与文字角柄相同)。手柄屏幕尺寸约 8pt,随 zoom 保持屏幕恒定,不吃 `fit`。
- 最小尺寸:矩形/椭圆归一化宽高均 ≥ `0.01`;直线/箭头两端像素距 ≥ `4pt`(折算归一化)。低于下限夹住,不要塌成点。
- 一次手势一条撤销(`pushUndo` 在手柄拖动首帧,与文字角柄一致)。
- 仍然只描边、不填充、无虚线/圆角/阴影、无旋转手柄。

### 2.2 纯函数(必须单测,放 `MarkupGeometry`)

```swift
enum ShapeHandle: Equatable, Sendable {
    case corner(ShapeCorner)   // nw/ne/sw/se
    case edge(ShapeEdge)       // n/s/w/e
    case endpoint(Bool)        // true = from, false = to
}
enum ShapeCorner { case nw, ne, sw, se }
enum ShapeEdge { case n, s, w, e }

static func shapeHandles(kind: ShapeKind, from: CGPoint, to: CGPoint) -> [(ShapeHandle, CGPoint)]
static func hitShapeHandle(kind: ShapeKind, from: CGPoint, to: CGPoint,
                           at point: CGPoint, tolerance: CGFloat) -> ShapeHandle?
static func reshaped(kind: ShapeKind, from: CGPoint, to: CGPoint,
                     handle: ShapeHandle, to point: CGPoint,
                     lockAspect: Bool) -> (from: CGPoint, to: CGPoint)
```

- `tolerance` 由调用方把约 10pt 折成归一化后传入(视口相关,纯函数不读 UI)。
- `reshaped` 内部夹取 0...1 与最小尺寸;lockAspect 仅 rect/ellipse 生效,line/arrow 忽略。
- 单测:八角/两端命中与否;角拖沿单轴仍改变尺寸;边拖只动一轴;锁比后宽高比不变;最小尺寸不塌;越界夹回单位矩形。

### 2.3 实现要点

- 手柄绘制:复用文字选区右下角手柄的视觉(白底黑边,容器坐标 ~8pt)。`MarkupCanvas.selectionOutline` 在 kind == shape 时画对应手柄。
- `handleDragStart` 前置 `hitShapeHandle`;命中则记 handle + 入撤销组,不走移动。
- `handleDragChange` 手柄态优先于 `moveSelected`,调用 `reshaped` 写回 from/to。
- `handleDragEnd` 清手柄态。方向键微调仍是平移整图元,不进手柄。
- 裁切工具的 8 手柄逻辑不要复用到标记层(坐标系/状态机不同);几何思路可参考 `CropMath.ratioLockedRect`,但函数放 `MarkupGeometry`。

### 2.4 C1 明确不做

填充、虚线、圆角、旋转、多选、自定义颜色(C2)。

---

## 3. C2 自定义颜色

`EDIT_UX_PLAN.md` §6.3 当时砍掉。改 Kind 签名会波及全部工具,必须单独一期,且先完成 C1。

### 3.1 模型

```swift
enum MarkupColor: Equatable, Sendable {
    case palette(Int)                       // 0...5,现有盘
    case custom(r: Double, g: Double, b: Double)  // 0...1 sRGB
}
```

`Annotation.Kind` 各 case 的 `colorIndex: Int` 改为 `color: MarkupColor`(text / stroke / shape;mosaic 无描边色则不动)。内存模型直接改,无落盘迁移。

- `MarkPalette.color(_:)` 改为 `MarkPalette.nsColor(_: MarkupColor)`。浅色描边规则:palette 仍 1/3 为浅;`custom` 按相对亮度 `(0.2126 r + 0.7152 g + 0.0722 b) > 0.65` 视为浅。
- 默认仍是 `.palette(2)`(红)。

### 3.2 UI

- 颜色弹层底部加 `NSColorWell`(包 `NSViewRepresentable`),选色写入 `.custom`。
- 六色盘点击仍写 `.palette`。选中自定义色时盘上不高亮任一日历色,Well 显示该 RGB。
- 不引入系统颜色面板以外的色盘库。

### 3.3 接线(编译器 switch 穷尽性兜底)

渲染器、命中无关、选区无关、`syncControlsFromSelection`、`applyColorToSelection`、导出。单测:`nsColor` 盘内越界回黑;custom 浅色判定边界;Kind 改写后现有渲染单测(文字填色/水印白)仍绿。

### 3.4 C2 明确不做

取色吸管、最近使用色列表、色盘扩展到 8+ 色、按图持久化调色盘。

---

## 4. C3 最近文件夹 + 当前目录监听

`PLAN.md` M5 写过「最近文件夹」,图标和偏好已有,这一项没有。目录监听是同文件「二期候选」里投入产出比最高的浏览项。

### 4.1 最近文件夹(不可砍)

- `UserDefaults` 记最多 8 条标准化目录 URL(书签 Data,不要只存 path 字符串——卷名/权限更稳;若书签失败再回退 path)。
- 每次 `openFolder` / 拖入目录成功后插入列表头、去重、截断。
- 入口:菜单「文件 → 最近打开的文件夹」+ 欢迎页列表。点一条:路径仍在则打开,不在则从列表剔除并提示。
- 菜单项「清除最近记录」。

### 4.2 当前目录监听(可砍)

- 只监听**当前选中文件夹**(不是全部根)。`DispatchSource.makeFileSystemObjectSource` 于 `FolderStore` 内,事件合并(≥ 300ms)后走现有 `refreshCurrentFolder`。
- 不递归监听子目录(与现有「点选某文件夹才列出其图」一致)。
- 应用退到后台可暂停,回到前台补一次刷新。
- 失败(权限/网络卷)静默,用户仍可用 `⌘R`。
- **C3 落地后**才允许打破 `AGENTS.md`「一期不做实时监听」;未做 C3 前不要改那条硬约束。

### 4.3 C3 明确不做

多根同时监听、文件系统全局监视器、iCloud 冲突 UI、自动打开新出现的文件。

---

## 5. C4 隐藏图单张恢复

现状:`hideImage` 后只能 `unhideAllInCurrentFolder` 或重启;`refreshCurrentFolder` 是否清空 hidden 不直观。

### 5.1 决策(冻结)

- 隐藏仍是**会话内、不落盘**(重启即全部可见)。这不是删除。
- 侧栏缩略图区已有「已隐藏 N 张 · 恢复」整夹入口。C4 补:
  1. 点「已隐藏 N 张」展开本夹隐藏列表(文件名,无强制缩略图),单项「显示」。
  2. `⌘R` / 目录监听刷新**不清空** hidden 集合(否则刚藏的图又冒出来)。
  3. 切换到别的文件夹再回来,hidden 仍在(现有 `hiddenByFolder` 已按文件夹键存,保持)。
- 删除进废纸篓仍要确认(若尚未有 `NSAlert`,本期一并补)。

### 5.2 C4 明确不做

跨会话记住隐藏、隐藏同步到 Finder 隐藏标志、撤销隐藏的 ⌘Z(浏览态没有撤销栈)。

---

## 6. D 候补(不要自行开工)

只有用户点名才做。会改变产品形态或已经试过失败。

| 项 | 说明 |
|---|---|
| 标注 sidecar 落盘 | A/B 明确不做;关窗即丢。一开就要格式版本与迁移 |
| 编辑画布放大后重解码原图 | B1 冻结 1500px 预览;导出已走原图。只影响马赛克精修清晰度 |
| JPEG 无损裁切 | oculante 有;要单独编解码路径 |
| 全质量 RAW(`CIRAWFilter`) | 现在用嵌入预览 |
| 打印取消/超时 | `UI_REVIEW` 遗留,超大图会卡住 |
| `revealExternalImages` 主线程扫盘异步化 | 大目录从 Finder 丢入会卡一下 |
| 横滑切图跟手 | 0.7.2–0.7.5 试过重影后撤回,禁止再开除非用户明确要求 |
| SVG / 超清 JXL / WebP 编码 / >100MP 分块 | `AGENTS.md` 可选二期,**不要引包** |

---

## 7. 明确不做(C/D 全期仍禁止)

与 `EDIT_UX_PLAN.md` §7、`MARKUP_PLAN.md` §12、`PLAN.md` 第七节一致,此处再钉一次:

- 图层列表、多选批量、标注层级调序
- 文字字体族 / 对齐 / 描边样式 / 自由变形(拖角柄只改字号)
- 形状填充、虚线、圆角、阴影、旋转
- PencilKit / 压感 / 任何第三方库
- 透视校正、批量裁切、批量水印文件夹
- 在主视图 `NSScrollView` 上直接涂鸦
- 收藏 / 标签、对比视图、视频
- 沙盒 / App Store(除非以后改定位)
- 参考或复制 GPL 项目代码

---

## 8. 每期门禁

- `swift build` 0 error;`swift test` 全绿(新增纯函数必须有单测)。
- 手工自测见各期决策段。
- 版本号同步(`build.sh`) + `README.md`「版本」一行 + `./build.sh`。
- UI 文案中文;手柄 / 最近文件夹菜单补 `.help`。

## 9. 代码锚点

| 路径 | 相关点 |
|---|---|
| `Sources/Pictool/Models/MarkupAnnotation.swift` | `Kind.shape` / `MarkupGeometry` / `MarkPalette`(C1/C2) |
| `Sources/Pictool/Views/EditView.swift` | 拖动手势、选区描边、颜色弹层 |
| `Sources/Pictool/Services/AnnotationRenderer.swift` | C2 颜色 |
| `Sources/Pictool/Models/FolderStore.swift` | 打开文件夹、refresh、hiddenByFolder(C3/C4) |
| `Sources/Pictool/Views/ThumbnailGridView.swift` | 隐藏 / 整夹恢复(C4) |
| `Sources/Pictool/PictoolApp.swift` | 文件菜单(C3 最近) |
| `Sources/Pictool/Views/MainContentView.swift` | 欢迎页(C3) |
| `Tests/PictoolTests/PictoolTests.swift` | 现有形状/裁切几何测试旁追加 |

## 10. 给执行 agent 的最小开场指令

只做用户点名的那一期。默认下一刀是 **C1**。

开场:

1. 读本文第 0 节 + 对应期章节,以及 `EDIT_UX_PLAN.md` 文档头。
2. C1 不要改 `Annotation.Kind` 关联值;C2 才改颜色。
3. 改纯函数就补 `Tests/PictoolTests/PictoolTests.swift`。
4. 合入升版本、写 README「版本」一行、跑 `./build.sh`。
