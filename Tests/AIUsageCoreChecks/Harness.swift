import Foundation

/// Minimal assertion harness so the checks run on a toolchain without XCTest.
enum Harness {
    static var failures = 0
    static var passes = 0

    static func check(_ condition: Bool, _ message: String, file: String = #fileID, line: Int = #line) {
        if condition {
            passes += 1
        } else {
            failures += 1
            print("FAIL \(file):\(line): \(message)")
        }
    }

    static func equal<T: Equatable>(_ a: T, _ b: T, _ message: String, file: String = #fileID, line: Int = #line) {
        check(a == b, "\(message) — got \(a), expected \(b)", file: file, line: line)
    }

    static func close(_ a: Double, _ b: Double, accuracy: Double = 1e-9, _ message: String, file: String = #fileID, line: Int = #line) {
        check(abs(a - b) <= accuracy, "\(message) — got \(a), expected \(b) ±\(accuracy)", file: file, line: line)
    }

    static func finish() -> Never {
        print("\(passes) passed, \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }
}
