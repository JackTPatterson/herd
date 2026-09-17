// Copied from Ghostty (https://github.com/ghostty-org/ghostty, commit 4a0e9e1) macOS sources.
// MIT License, Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors. See LICENSE-ghostty.
import Carbon

class KeyboardLayout {
    /// Return a string ID of the current keyboard input source.
    static var id: String? {
        if let source = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
           let sourceIdPointer = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) {
            let sourceId = unsafeBitCast(sourceIdPointer, to: CFString.self)
            return sourceId as String
        }

        return nil
    }
}
