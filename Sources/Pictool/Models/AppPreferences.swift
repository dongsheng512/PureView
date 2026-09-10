import Foundation

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

/// 最近打开的文件夹。UserDefaults 存书签 Data + path 回退,最多 8 条。
enum RecentFolders {
    static let storageKey = "recentFolders"
    static let maxCount = 8

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
