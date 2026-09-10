import Foundation

/// 一把锁 + 一个值。
///
/// 存在的理由:`DispatchQueue.concurrentPerform`、`NSItemProvider.loadObject` 这类
/// API 的回调是 `@Sendable` 的,Swift 6 语言模式下不允许直接在回调里读写捕获的局部 `var`
/// (`SendableClosureCaptures`)。把共享状态收进这个盒子后,闭包捕获的是一个
/// `@unchecked Sendable` 对象,而互斥仍由内部的 `NSLock` 保证,语义与原来完全一致。
///
/// 只做互斥,不做别的。`withLock` 内部要短——不要在锁里做 IO 或重活。
final class Locked<Value: Sendable>: @unchecked Sendable {

    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) {
        self.value = value
    }

    /// 在锁内访问值。闭包可以改它,返回值由调用方决定。
    func withLock<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    /// 取一份当前值的拷贝。值类型走写时复制,通常只是一次 retain。
    func read() -> Value {
        withLock { $0 }
    }
}
