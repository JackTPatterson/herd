// Copied from Ghostty (https://github.com/ghostty-org/ghostty, commit 4a0e9e1) macOS sources.
// MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. See LICENSE-ghostty.
extension Optional where Wrapped == String {
    /// Executes a closure with a C string pointer, handling nil gracefully.
    func withCString<T>(_ body: (UnsafePointer<Int8>?) throws -> T) rethrows -> T {
        if let string = self {
            return try string.withCString(body)
        } else {
            return try body(nil)
        }
    }
}
