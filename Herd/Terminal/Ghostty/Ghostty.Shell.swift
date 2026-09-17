// Copied from Ghostty (https://github.com/ghostty-org/ghostty, commit 4a0e9e1) macOS sources.
// MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. See LICENSE-ghostty.
extension Ghostty {
    enum Shell {
        // Characters to escape in the shell.
        private static let escapeCharacters = "\\ ()[]{}<>\"'`!#$&;|*?\t"

        /// Escape shell-sensitive characters in a string by prefixing each with a
        /// backslash. Suitable for inserting paths/URLs into a live terminal buffer.
        static func escape(_ str: String) -> String {
            var result = str
            for char in escapeCharacters {
                result = result.replacingOccurrences(
                    of: String(char),
                    with: "\\\(char)"
                )
            }

            return result
        }
    }
}
