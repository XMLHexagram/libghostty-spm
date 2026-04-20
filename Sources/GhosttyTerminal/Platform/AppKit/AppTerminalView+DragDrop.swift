//
//  AppTerminalView+DragDrop.swift
//  libghostty-spm
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    extension AppTerminalView {
        override public func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
            guard sender.draggingPasteboard.canReadObject(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true])
            else { return [] }
            return .copy
        }

        override public func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
            guard let urls = sender.draggingPasteboard.readObjects(
                forClasses: [NSURL.self],
                options: [.urlReadingFileURLsOnly: true]
            ) as? [URL], !urls.isEmpty else { return false }

            let paths = urls.map { shellEscape($0.path) }
            let text = paths.joined(separator: " ")
            insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }

        private func shellEscape(_ path: String) -> String {
            // Single-quote the path, escaping any existing single quotes
            let escaped = path.replacingOccurrences(of: "'", with: "'\\''")
            return "'\(escaped)'"
        }
    }
#endif
