import CoreTransferable
import SakuraCordModels
import SwiftUI
import UniformTypeIdentifiers

nonisolated struct ServerOrderDragItem: Codable, Transferable {
    let itemID: GuildRailItem.RailIdentifier
    let accountID: String
    let pickerID: UUID

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: UTType(exportedAs: "dev.sakuracord.server-order-item", conformingTo: .data))
            .visibility(.ownProcess)
    }
}

struct ServerOrderDragModifier: ViewModifier {
    let item: ServerOrderDragItem
    let isEnabled: Bool
    let move: (ServerOrderDragItem, ServerOrderPlacement) -> Void
    let dragActivityChanged: (Bool) -> Void

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(Rectangle())
                .draggable(item)
                .dragConfiguration(.init(allowMove: true))
                .onDragSessionUpdated { session in
                    switch session.phase {
                    case .initial, .active: dragActivityChanged(true)
                    default: dragActivityChanged(false)
                    }
                }
                .modifier(ServerOrderDropModifier(itemID: item.itemID, isEnabled: true, move: move))
        } else {
            content
        }
    }
}

struct ServerOrderDropModifier: ViewModifier {
    let itemID: GuildRailItem.RailIdentifier?
    let isEnabled: Bool
    let move: (ServerOrderDragItem, ServerOrderPlacement) -> Void
    @State private var dropAfter: Bool?

    func body(content: Content) -> some View {
        content
            .overlay(alignment: dropAfter == true ? .bottom : .top) {
                if dropAfter != nil {
                    Capsule()
                        .fill(SakuraCordAccentColor.color)
                        .frame(height: 2)
                        .allowsHitTesting(false)
                }
            }
            .dropDestination(for: ServerOrderDragItem.self, isEnabled: isEnabled) { items, session in
                guard items.count == 1, let item = items.first else { return }
                let after = session.location.y >= session.size.height / 2
                let placement: ServerOrderPlacement = if let itemID {
                    if after { .after(itemID) } else { .before(itemID) }
                } else {
                    .end
                }
                dropAfter = nil
                move(item, placement)
            }
            .dropConfiguration { session in
                DropConfiguration(operation: isEnabled && session.itemsCount == 1 ? .move : .forbidden)
            }
            .onDropSessionUpdated { session in
                switch session.phase {
                case .entering, .active:
                    dropAfter = isEnabled ? session.location.y >= session.size.height / 2 : nil
                default:
                    dropAfter = nil
                }
            }
    }
}

/// Scrolls the picker while a server drag hovers at its top or bottom edge,
/// which SwiftUI's scroll view does not do on its own. The edge zones exist
/// only during a drag and only while the list can still scroll that way, so
/// they never cover a row that could otherwise be clicked or dropped on.
struct ServerOrderAutoscrollModifier: ViewModifier {
    private static let edgeHeight: CGFloat = 32
    private static let step: CGFloat = 7

    let isDragActive: Bool
    @State private var position = ScrollPosition()
    @State private var geometry: ScrollGeometry?
    @State private var direction: CGFloat = 0
    @State private var task: Task<Void, Never>?

    func body(content: Content) -> some View {
        content
            .scrollPosition($position)
            .onScrollGeometryChange(
                for: ScrollGeometry.self,
                of: { $0 },
                action: { _, newGeometry in geometry = newGeometry }
            )
            .overlay(alignment: .top) { edge(scrolling: -1) }
            .overlay(alignment: .bottom) { edge(scrolling: 1) }
            .onChange(of: isDragActive) { _, isActive in
                if !isActive { scroll(0) }
            }
    }

    @ViewBuilder
    private func edge(scrolling edgeDirection: CGFloat) -> some View {
        if isDragActive, bound(edgeDirection) != nil {
            Color.clear
                .frame(height: Self.edgeHeight)
                .contentShape(Rectangle())
                .dropDestination(for: ServerOrderDragItem.self) { _, _ in }
                .dropConfiguration { _ in DropConfiguration(operation: .forbidden) }
                .onDropSessionUpdated { session in
                    switch session.phase {
                    case .entering, .active: scroll(edgeDirection)
                    default: scroll(0)
                    }
                }
        }
    }

    /// The farthest offset in a direction, or nil once the list is already there.
    private func bound(_ direction: CGFloat) -> CGFloat? {
        guard let geometry else { return nil }
        let bound = direction < 0
            ? -geometry.contentInsets.top
            : geometry.contentSize.height - geometry.containerSize.height
                + geometry.contentInsets.bottom
        return (bound - geometry.contentOffset.y) * direction > 0.5 ? bound : nil
    }

    private func scroll(_ newDirection: CGFloat) {
        guard newDirection != direction else { return }
        direction = newDirection
        task?.cancel()
        task = nil
        guard newDirection != 0 else { return }
        task = Task { @MainActor in
            while !Task.isCancelled, let bound = bound(newDirection), let geometry {
                let next = geometry.contentOffset.y + newDirection * Self.step
                position.scrollTo(y: newDirection < 0 ? max(bound, next) : min(bound, next))
                try? await Task.sleep(for: .milliseconds(16))
            }
            // Reaching the edge removes its zone before any exit update arrives.
            if !Task.isCancelled { direction = 0 }
        }
    }
}
