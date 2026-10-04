import Foundation

/// 进程内编辑会话。关编辑 / 切图不丢,退出应用即丢。不写盘。
@MainActor
@Observable
final class AnnotationStore {
    private var sessions: [String: EditSession] = [:]
    /// 编辑器 ⌘C/⌘V 的内存剪贴板(不写系统粘贴板,退出即丢)
    private(set) var clipboard: Annotation?

    func hasSession(for url: URL) -> Bool {
        sessions[Self.storageKey(for: url)] != nil
    }

    func session(for url: URL) -> EditSession {
        sessions[Self.storageKey(for: url)] ?? EditSession()
    }

    func setSession(_ session: EditSession, for url: URL) {
        let key = Self.storageKey(for: url)
        if session.isPristine {
            sessions.removeValue(forKey: key)
        } else {
            sessions[key] = session
        }
    }

    func annotations(for url: URL) -> [Annotation] {
        session(for: url).annotations
    }

    /// 只替换标记,裁切和旋转留在原会话里。全空且几何是初始值时整段丢掉。
    func set(_ annotations: [Annotation], for url: URL) {
        var session = session(for: url)
        session.annotations = annotations
        setSession(session, for: url)
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
