import CoreGraphics
import Foundation

/// 左右切图、点缩略图时的过渡。默认跟手翻页;淡入是原先的单层效果。
enum ImageTransitionStyle: String, CaseIterable, Identifiable {
    /// 拖拽或触控板时图片跟着手指走。往左滑出下一张(从右边进来),往右滑回上一张。
    /// 松手未过线则弹回。方向键和按钮也是同一套整页滑移。无方向(点缩略图)只交叉淡化。
    case slide
    /// 新图从透明淡入,并沿方向滑 24pt。
    case fade

    static let storageKey = "imageTransitionStyle"
    static let defaultValue = ImageTransitionStyle.slide

    var id: String { rawValue }

    var label: String {
        switch self {
        case .slide: "跟手翻页"
        case .fade: "淡入"
        }
    }
}

/// 当前图的前一张和后一张。只有一张、或那一侧到头且不循环时为 nil。
struct ImageNeighbors: Equatable, Sendable {
    var previous: URL?
    var next: URL?

    var urls: [URL] {
        [previous, next].compactMap { $0 }
    }

    func url(direction: Int) -> URL? {
        if direction > 0 { return next }
        if direction < 0 { return previous }
        return nil
    }
}

/// 交叠滑移的时长与位移。纯函数,方便单测。
enum ImageHandoff {
    /// 有方向的整页滑移 380ms,连按还没放完时 220ms。无方向交叉淡化 160ms / 100ms。
    static func duration(direction: Int, rapid: Bool) -> TimeInterval {
        if direction == 0 { return rapid ? 0.10 : 0.16 }
        return rapid ? 0.22 : 0.38
    }

    /// 松手后的弹簧。`distance` 是还要走的位移(落点减现在),`velocity` 是手指速度,点/秒。
    /// `initialVelocity` 朝向落点为正,1 表示按这个速度一秒能走完剩下的路。
    struct PagingRelease: Equatable {
        var perceptualDuration: TimeInterval
        var bounce: CGFloat
        var initialVelocity: CGFloat
    }

    static func pagingRelease(distance: CGFloat, velocity: CGFloat) -> PagingRelease {
        let remaining = abs(distance)
        let speed = abs(velocity)
        let perceptualDuration: TimeInterval
        if speed > 900, remaining > 1 {
            // 快甩时顺着当前速度把剩下的路走完,不要先停一下再起步。
            perceptualDuration = min(0.46, max(0.26, TimeInterval(remaining / speed) * 1.35))
        } else if remaining < 48 {
            perceptualDuration = 0.28
        } else {
            perceptualDuration = 0.40
        }
        var initialVelocity: CGFloat = 0
        if remaining > 1 {
            initialVelocity = velocity / distance
        }
        if !initialVelocity.isFinite { initialVelocity = 0 }
        initialVelocity = min(6, max(-6, initialVelocity))
        // 略过阻尼,停在落点上,不冲进再下一张。
        return PagingRelease(
            perceptualDuration: perceptualDuration,
            bounce: -0.18,
            initialVelocity: initialVelocity
        )
    }

    /// 视口宽度的 8%,对齐到物理像素。半像素位移会在滑开的那一侧留一条深边。无方向不滑。
    static func travel(direction: Int, viewportWidth: CGFloat, backing: CGFloat = 1) -> CGFloat {
        guard direction != 0, viewportWidth > 0 else { return 0 }
        let scale = backing > 0 ? backing : 1
        return (viewportWidth * 0.08 * scale).rounded() / scale
    }

    /// 换图会改 clip 的 bounds.origin。把旧图 frame 换算到新 origin 下,屏幕位置不变。
    static func parkedFrame(oldImageFrame: CGRect, oldBoundsOrigin: CGPoint, newBoundsOrigin: CGPoint) -> CGRect {
        CGRect(
            x: oldImageFrame.origin.x - oldBoundsOrigin.x + newBoundsOrigin.x,
            y: oldImageFrame.origin.y - oldBoundsOrigin.y + newBoundsOrigin.y,
            width: oldImageFrame.width,
            height: oldImageFrame.height
        )
    }

    /// 两页之间的缝。相册翻页不是贴在一起滑的。
    static let pageGap: CGFloat = 20
    /// 慢拖要过视口的这个比例才翻页,避免轻碰一下图就自己跑走。
    static let commitFraction: CGFloat = 0.34
    /// 超过这个速度(点/秒),并且已经顺手挪开一点,算甩动,不用拖过比例线。
    static let flickSpeed: CGFloat = 680
    static let flickMinimumTravel: CGFloat = 20
    /// 用速度外推这么久,估松手后会落在哪。
    static let projectionTime: CGFloat = 0.22
    /// 把触控板 `scrollingDeltaX` 换成手指方向。返回值 > 0 表示手指向右。
    /// 自然滚动打开时,系统已经把 delta 倒成「内容跟手」;关掉时仍是设备原值(手指向左为正),这里再倒回来。
    /// 翻页要跟手指,不跟滚动条偏好。鼠标拖拽不走这里。
    static func trackpadFingerDelta(_ scrollingDelta: CGFloat, naturalScrolling: Bool) -> CGFloat {
        naturalScrolling ? scrollingDelta : -scrollingDelta
    }

    /// 松手后的纯惯性。手指已经按上时不能吞,否则连着滑时新手势还带着上一段的惯性标记,画面会空转一阵。
    static func shouldSwallowPagingMomentum(fingerDown: Bool, momentum: Bool, armed: Bool) -> Bool {
        armed && momentum && !fingerDown
    }

    /// 这次滚轮要不要交给跟手翻页。鼠标滚轮没有手指相位,不走这里。
    /// 文档本身能横向滚动时仍是平移。纯惯性不跟手。
    static func shouldTrackPagingScroll(
        fingerDown: Bool,
        momentum: Bool,
        horizontal: Bool,
        gestureActive: Bool,
        documentScrollsHorizontally: Bool
    ) -> Bool {
        if documentScrollsHorizontally { return false }
        if !fingerDown && !gestureActive { return false }
        if momentum && !fingerDown { return false }
        return gestureActive || horizontal
    }

    /// 邻图相对当前图的水平偏移。相册方向:下一张在右边,上一张在左边。
    /// 内容跟着手指走,往左拖才把右边的下一张拉进来。
    static func pageOffset(direction: Int, viewportWidth: CGFloat, gap: CGFloat = pageGap) -> CGFloat {
        guard direction != 0, viewportWidth > 0 else { return 0 }
        return CGFloat(direction) * (viewportWidth + gap)
    }

    /// 松手后内容要落到的位移。与 `pageOffset` 相反,才能把那一侧的图拉到视口中央。
    static func commitTranslation(direction: Int, viewportWidth: CGFloat, gap: CGFloat = pageGap) -> CGFloat {
        guard direction != 0, viewportWidth > 0 else { return 0 }
        return -CGFloat(direction) * (viewportWidth + gap)
    }

    /// 跟手位移。手指往哪,图往哪,有邻图时 1:1,最多拉过一整页。
    /// 往左(负)是下一张,往右(正)是上一张。到头则走系统滚动那条橡皮筋。
    static func presentedTranslation(
        raw: CGFloat,
        viewportWidth: CGFloat,
        hasNext: Bool,
        hasPrevious: Bool
    ) -> CGFloat {
        guard viewportWidth > 0, raw != 0 else { return 0 }
        let travel = viewportWidth + pageGap
        if raw < 0 {
            return hasNext ? max(raw, -travel) : rubberBand(raw, dimension: viewportWidth)
        }
        return hasPrevious ? min(raw, travel) : rubberBand(raw, dimension: viewportWidth)
    }

    /// 系统滚动的橡皮筋。`dimension` 用视口宽度,系数 0.55。越拉越沉,但不会一下子顶死。
    static func rubberBand(_ translation: CGFloat, dimension: CGFloat, coefficient: CGFloat = 0.55) -> CGFloat {
        guard dimension > 0, translation != 0 else { return 0 }
        let sign: CGFloat = translation < 0 ? -1 : 1
        let x = abs(translation)
        let resisted = (1 - (1 / (x * coefficient / dimension + 1))) * dimension
        return sign * resisted
    }

    /// 松手往哪翻。translation < 0 是内容左移(手指向左),走向下一张。
    /// 慢拖要过 `commitFraction`;顺手甩动过 `flickSpeed` 则提前翻。否则弹回。
    static func commitDirection(translation: CGFloat, velocity: CGFloat, viewportWidth: CGFloat) -> Int {
        guard viewportWidth > 1 else { return 0 }
        if velocity <= -flickSpeed, translation < -flickMinimumTravel { return 1 }
        if velocity >= flickSpeed, translation > flickMinimumTravel { return -1 }
        let projected = translation + velocity * projectionTime
        let threshold = viewportWidth * commitFraction
        if projected <= -threshold { return 1 }
        if projected >= threshold { return -1 }
        return 0
    }

    /// 松手已经决定翻页、弹簧还没停又按住。
    /// `shift` 是旧画布的位移,`commitTranslation` 是这次要落到的位移。
    /// 返回值把刚翻到的那张当成 0,接住的那一帧画面不跳。
    static func translationAfterCommittedInterrupt(shift: CGFloat, commitTranslation: CGFloat) -> CGFloat {
        shift - commitTranslation
    }

    /// 接住已提交的翻页之后,松手判定用相对接住点的位移。
    /// 没走完的弹簧不能算成手指又往回翻了一页。
    static func pagingDecisionTranslation(
        presented: CGFloat,
        grabbedFromCommit: Bool,
        grabTranslation: CGFloat
    ) -> CGFloat {
        grabbedFromCommit ? presented - grabTranslation : presented
    }

    /// 邻图在视口里的适配矩形,原点在视口中心对齐后的左下角。边缘对齐到物理像素。
    static func fittedRect(imageSize: CGSize, viewport: CGSize, backing: CGFloat = 1) -> CGRect {
        guard imageSize.width > 1, imageSize.height > 1, viewport.width > 1, viewport.height > 1 else {
            return .zero
        }
        let scale = backing > 0 ? backing : 1
        func snap(_ value: CGFloat) -> CGFloat { (value * scale).rounded() / scale }
        let fit = min(viewport.width / imageSize.width, viewport.height / imageSize.height)
        let size = CGSize(width: snap(imageSize.width * fit), height: snap(imageSize.height * fit))
        return CGRect(
            x: snap((viewport.width - size.width) / 2),
            y: snap((viewport.height - size.height) / 2),
            width: size.width,
            height: size.height
        )
    }
}

/// 打开新图时的默认缩放
enum OpenZoomMode: String, CaseIterable, Identifiable {
    case fit
    case actualSize

    static let storageKey = "openZoomMode"
    static let defaultValue = OpenZoomMode.fit

    var id: String { rawValue }

    var label: String {
        switch self {
        case .fit: "适配窗口"
        case .actualSize: "实际大小"
        }
    }
}

/// 图片列表排序键
enum ImageSortKey: String, CaseIterable, Identifiable {
    case name
    case modified
    case captured
    case size

    static let storageKey = "imageSortKey"
    static let defaultValue = ImageSortKey.name

    var id: String { rawValue }

    var label: String {
        switch self {
        case .name: "文件名"
        case .modified: "修改时间"
        case .captured: "拍摄时间"
        case .size: "文件大小"
        }
    }
}

enum ImageSortDirection: String, CaseIterable, Identifiable {
    case ascending
    case descending

    static let storageKey = "imageSortDirection"
    static let defaultValue = ImageSortDirection.ascending

    var id: String { rawValue }

    var label: String {
        switch self {
        case .ascending: "升序"
        case .descending: "降序"
        }
    }
}

struct ImageSortPreference: Equatable, Sendable {
    var key: ImageSortKey
    var direction: ImageSortDirection

    static let `default` = ImageSortPreference(key: .name, direction: .ascending)

    static func load(from defaults: UserDefaults = .standard) -> ImageSortPreference {
        let key = ImageSortKey(rawValue: defaults.string(forKey: ImageSortKey.storageKey) ?? "")
            ?? ImageSortKey.defaultValue
        let direction = ImageSortDirection(rawValue: defaults.string(forKey: ImageSortDirection.storageKey) ?? "")
            ?? ImageSortDirection.defaultValue
        return ImageSortPreference(key: key, direction: direction)
    }
}

enum WrapNavigation {
    static let storageKey = "wrapImageNavigation"
    static let defaultValue = true
}

/// 幻灯片播放间隔(秒)。间隔下限 1 秒,防止大图解码慢时永远在转圈。
enum SlideShowInterval: Int, CaseIterable, Identifiable {
    case s1 = 1
    case s2 = 2
    case s3 = 3
    case s5 = 5
    case s10 = 10

    static let storageKey = "slideshowInterval"
    static let defaultValue = SlideShowInterval.s2

    var id: Int { rawValue }
    var seconds: Int { rawValue }
    var label: String { "\(rawValue) 秒" }

    /// 下一档(HUD 上循环切换用)
    var next: SlideShowInterval {
        let all = SlideShowInterval.allCases
        let idx = all.firstIndex(of: self) ?? 0
        return all[(idx + 1) % all.count]
    }

    static func load(from defaults: UserDefaults = .standard) -> SlideShowInterval {
        SlideShowInterval(rawValue: defaults.integer(forKey: storageKey)) ?? defaultValue
    }
}

/// 导出质量(仅 JPEG / HEIC 这类有损格式生效;PNG/TIFF 无损,面板里不显示滑杆)。
/// 默认 0.92 沿用改动前的硬编码值——升级后观感不变,只是多了一个可调入口。
enum ExportQuality {
    static let storageKey = "exportQuality"
    static let defaultValue = 0.92
    /// 下限 0.3:再低就只剩轮廓,不如换 PNG。
    static let range: ClosedRange<Double> = 0.3...1.0

    /// 显示成整百分数(滑杆右侧读数)。夹取到合法区间并挡掉 NaN——
    /// UserDefaults 里可能残留旧版本或手改 plist 写进去的越界值。
    static func percentLabel(_ value: Double) -> String {
        let v = value.isFinite ? min(max(value, range.lowerBound), range.upperBound) : defaultValue
        return "\(Int((v * 100).rounded()))%"
    }
}

/// 导出是否写入 GPS 坐标。默认开启,与改动前的行为一致。
enum ExportGPS {
    static let storageKey = "exportIncludeGPS"
    static let defaultValue = true
}

/// 侧栏正上方那一段(红绿灯所在列)的配色
enum SidebarTopStyle: String, CaseIterable, Identifiable {
    /// 与侧栏同色,整列通到窗口顶,和主区顶栏分开
    case followSidebar
    /// 与主区顶栏同色,通栏工具条
    case followChrome

    static let storageKey = "sidebarTopStyle"
    static let defaultValue = SidebarTopStyle.followSidebar

    var id: String { rawValue }

    var label: String {
        switch self {
        case .followSidebar: "跟随侧栏"
        case .followChrome: "与顶栏同色"
        }
    }
}

/// 最近打开的文件夹。UserDefaults 存书签 Data + path 回退,最多 5 条。
enum RecentFolders {
    static let storageKey = "recentFolders"
    static let maxCount = 5

    struct Item: Equatable, Identifiable, Sendable {
        var url: URL
        var bookmark: Data?

        var id: String { canonical(url).path }

        var name: String {
            let n = url.lastPathComponent
            return n.isEmpty ? url.path : n
        }

        var displayPath: String { url.path }
    }

    /// 目录身份:标准化 + 统一成 isDirectory,避免 `/foo` 与 `/foo/` 各占一条。
    static func canonical(_ url: URL) -> URL {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") {
            path.removeLast()
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    struct Record: Codable, Equatable {
        var path: String
        var bookmark: Data?
    }

    /// 插入列表头、按标准化路径去重、截断。纯函数,单测覆盖。
    static func inserting(_ url: URL, into items: [Item], bookmark: Data? = nil,
                          maxCount: Int = maxCount) -> [Item] {
        let key = canonical(url)
        var next = items.filter { canonical($0.url) != key }
        next.insert(Item(url: key, bookmark: bookmark), at: 0)
        if next.count > maxCount {
            next = Array(next.prefix(maxCount))
        }
        return next
    }

    static func removing(_ url: URL, from items: [Item]) -> [Item] {
        let key = canonical(url)
        return items.filter { canonical($0.url) != key }
    }

    static func load(from defaults: UserDefaults = .standard) -> [Item] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([Record].self, from: data) else {
            return []
        }
        var items: [Item] = []
        var seen = Set<String>()
        for record in records {
            guard let item = resolve(record) else { continue }
            let path = canonical(item.url).path
            if seen.contains(path) { continue }
            seen.insert(path)
            items.append(item)
            if items.count == maxCount { break }
        }
        return items
    }

    static func remember(_ url: URL, in defaults: UserDefaults = .standard) -> [Item] {
        let standardized = canonical(url)
        let bookmark = try? standardized.bookmarkData(
            options: [],
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
        let items = inserting(standardized, into: load(from: defaults), bookmark: bookmark)
        save(items, to: defaults)
        return items
    }

    static func remove(_ url: URL, from defaults: UserDefaults = .standard) -> [Item] {
        let items = removing(url, from: load(from: defaults))
        save(items, to: defaults)
        return items
    }

    static func clear(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: storageKey)
    }

    static func save(_ items: [Item], to defaults: UserDefaults) {
        let records = items.map { Record(path: $0.url.path, bookmark: $0.bookmark) }
        defaults.set(try? JSONEncoder().encode(records), forKey: storageKey)
    }

    /// 书签能解析则用解析结果(卷重挂后路径可能变);否则回退 path。
    static func resolve(_ record: Record) -> Item? {
        if let data = record.bookmark {
            var stale = false
            if let resolved = try? URL(
                resolvingBookmarkData: data,
                options: [],
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) {
                let url = canonical(resolved)
                var bookmark = data
                if stale {
                    bookmark = (try? url.bookmarkData(
                        options: [],
                        includingResourceValuesForKeys: nil,
                        relativeTo: nil
                    )) ?? data
                }
                return Item(url: url, bookmark: bookmark)
            }
        }
        guard !record.path.isEmpty else { return nil }
        return Item(url: canonical(URL(fileURLWithPath: record.path)), bookmark: record.bookmark)
    }
}

/// 切图下标换算(纯函数,单测覆盖循环/夹取)
enum ImageNavigation {
    /// 返回下一张下标;越界且不循环时返回 nil。单张循环时仍返回 0。
    static func nextIndex(current: Int, count: Int, delta: Int, wrap: Bool) -> Int? {
        guard count > 0 else { return nil }
        let base = current < 0 ? 0 : current
        let next = base + delta
        if wrap {
            return ((next % count) + count) % count
        }
        guard (0..<count).contains(next) else { return nil }
        return next
    }
}
