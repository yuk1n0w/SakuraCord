import AppKit
import OSLog
import SwiftUI

struct ComposerPromisedFileDropBridge: NSViewRepresentable {
    var isEnabled: Bool
    let targetChanged: (_ isTargeted: Bool, _ location: CGPoint, _ isInstant: Bool) -> Void
    let receiveFiles: (
        _ batch: ComposerPromisedFileBatch,
        _ location: CGPoint,
        _ isInstant: Bool
    ) -> Void

    func makeNSView(context _: Context) -> ComposerPromisedFileDropView {
        ComposerPromisedFileDropView(
            isEnabled: isEnabled,
            targetChanged: targetChanged,
            receiveFiles: receiveFiles
        )
    }

    func updateNSView(_ view: ComposerPromisedFileDropView, context _: Context) {
        view.isEnabled = isEnabled
        view.targetChanged = targetChanged
        view.receiveFiles = receiveFiles
    }
}

final class ComposerPromisedFileDropView: NSView {
    var isEnabled: Bool
    var targetChanged: (Bool, CGPoint, Bool) -> Void
    var receiveFiles: (ComposerPromisedFileBatch, CGPoint, Bool) -> Void

    init(
        isEnabled: Bool,
        targetChanged: @escaping (Bool, CGPoint, Bool) -> Void,
        receiveFiles: @escaping (ComposerPromisedFileBatch, CGPoint, Bool) -> Void
    ) {
        self.isEnabled = isEnabled
        self.targetChanged = targetChanged
        self.receiveFiles = receiveFiles
        super.init(frame: .zero)
        registerForDraggedTypes(ComposerPromisedFileReception.draggedTypes)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        updateTarget(sender)
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) {
        targetChanged(false, .zero, false)
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard isEnabled else { return false }
        let location = convert(sender.draggingLocation, from: nil)
        let isInstant = NSEvent.modifierFlags.contains(.shift)
        let didStart = ComposerPromisedFileReception.receive(
            from: sender.draggingPasteboard
        ) { [receiveFiles] batch in
            receiveFiles(batch, location, isInstant)
        }
        targetChanged(false, .zero, false)
        return didStart
    }

    static func makeReceivingDirectory(fileManager: FileManager = .default) throws -> URL {
        try ComposerPromisedFileStorage.makeReceivingDirectory(
            fileManager: fileManager
        )
    }

    private func updateTarget(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let location = convert(sender.draggingLocation, from: nil)
        let isInstant = NSEvent.modifierFlags.contains(.shift)
        let acceptsDrop = isEnabled
            && ComposerPromisedFileReception.hasPromises(on: sender.draggingPasteboard)
        targetChanged(acceptsDrop, location, isInstant)
        return acceptsDrop ? .copy : []
    }
}

/// Receives file promises, such as the image behind a screenshot thumbnail,
/// into SakuraCord's own promised-attachment storage.
///
/// A screenshot thumbnail also offers a path to a temporary file that it moves
/// away once the drag or paste finishes. Every drop and paste path prefers the
/// promise, so the attachment is a stable copy rather than a vanishing path.
@MainActor
enum ComposerPromisedFileReception {
    private static let logger = Logger(
        subsystem: "dev.sakuracord.SakuraCord",
        category: "PromisedAttachments"
    )

    static var draggedTypes: [NSPasteboard.PasteboardType] {
        NSFilePromiseReceiver.readableDraggedTypes.map {
            NSPasteboard.PasteboardType($0)
        }
    }

    static func hasPromises(on pasteboard: NSPasteboard) -> Bool {
        !receivers(on: pasteboard).isEmpty
    }

    /// Asks each promise's source to write its file into a fresh managed
    /// directory, then delivers the batch on the main queue. Returns false
    /// when the pasteboard carries no promises, so callers can fall back to
    /// ordinary file URLs.
    @discardableResult
    static func receive(
        from pasteboard: NSPasteboard,
        completion: @escaping (ComposerPromisedFileBatch) -> Void
    ) -> Bool {
        let receivers = receivers(on: pasteboard)
        guard !receivers.isEmpty else { return false }
        let directory: URL
        do {
            directory = try ComposerPromisedFileStorage.makeReceivingDirectory()
        } catch {
            logger.error(
                "Could not create a promised-attachment directory: \(error.localizedDescription, privacy: .public)"
            )
            return false
        }
        // Each receiver represents one promised file. `fileTypes` lists the
        // representations that file can provide; it is not a callback count.
        let collector = ComposerPromisedFileCollector(
            expectedCount: receivers.count,
            directory: directory,
            completion: completion
        )
        for receiver in receivers {
            receiver.receivePromisedFiles(
                atDestination: directory,
                options: [:],
                operationQueue: .main
            ) { url, error in
                if let error {
                    logger.error(
                        "A promised attachment was not delivered: \(error.localizedDescription, privacy: .public)"
                    )
                }
                collector.receive(url: url, error: error)
            }
        }
        return true
    }

    private static func receivers(on pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        pasteboard.readObjects(
            forClasses: [NSFilePromiseReceiver.self],
            options: nil
        ) as? [NSFilePromiseReceiver] ?? []
    }
}

struct ComposerAttachmentEditorTarget: Identifiable {
    let id: UUID
}

@MainActor
final class ComposerPromisedFileCollector {
    private var remainingCount: Int
    private var receivedURLs: [URL] = []
    private let directory: URL
    private let completion: (ComposerPromisedFileBatch) -> Void

    init(
        expectedCount: Int,
        directory: URL,
        completion: @escaping (ComposerPromisedFileBatch) -> Void
    ) {
        remainingCount = expectedCount
        self.directory = directory
        self.completion = completion
    }

    func receive(url: URL, error: Error?) {
        if error == nil {
            receivedURLs.append(url)
        }
        remainingCount -= 1
        if remainingCount == 0 {
            let batch = ComposerPromisedFileBatch(
                directory: directory,
                urls: receivedURLs
            )
            if receivedURLs.isEmpty {
                batch.discard()
            }
            completion(batch)
        }
    }
}
