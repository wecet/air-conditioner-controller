import Foundation

struct OffTimer {
    private(set) var deadline: Date?
    mutating func start(seconds: TimeInterval, now: Date = Date()) {
        guard seconds.isFinite, seconds > 0 else { return }
        deadline = now.addingTimeInterval(seconds)
    }
    mutating func cancel() { deadline = nil }
    func isDue(at now: Date) -> Bool { deadline.map { now >= $0 } ?? false }
    func remaining(at now: Date) -> Int? {
        deadline.map { Int(ceil(max(0, $0.timeIntervalSince(now)))) }
    }
    func countdown(at now: Date) -> String? {
        guard let seconds = remaining(at: now) else { return nil }
        if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}
