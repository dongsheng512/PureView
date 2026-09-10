import Foundation

/// 进程内标记缓存。关 sheet / 切图不丢,退出即丢。
@MainActor
@Observable
final class AnnotationStore {
    private var items: [String: [Annotation]] = [:]
    /// 编辑器 ⌘C/⌘V 的内存剪贴板(不写系统粘贴板,退出即丢)
    private(set) var clipboard: Annotation?

    func annotations(for url: URL) -> [Annotation] {
        items[Self.storageKey(for: url)] ?? []
    }

    func set(_ annotations: [Annotation], for url: URL) {
        let key = Self.storageKey(for: url)
        if annotations.isEmpty {
            items.removeValue(forKey: key)
        } else {
            items[key] = annotations
        }
    }

    func copyToClipboard(_ annotation: Annotation) {
        clipboard = annotation
    }

    /// 去掉尾斜杠,避免 `/tmp/a.jpg` 与 `/tmp/a.jpg/` 各存一份。
    static func storageKey(for url: URL) -> String {
        var path = url.standardizedFileURL.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}
