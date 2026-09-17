import Observation
import SakuraCordModels
import SwiftUI

/// Keeps rail observation out of the workspace root. Timeline, member-list,
/// composer, and loading publications can invalidate `ChatRootView` without
/// rebuilding or comparing every server row.
struct ServerRailContainer: View {
    let model: AppModel

    var body: some View {
        ServerRailView(
            items: model.serverRailPresentation.items,
            home: model.serverRailPresentation.home,
            selectHome: { model.selectGuild(nil) },
            selectGuild: model.selectGuild,
            contextMenuActions: ServerRailContextMenuActions(
                markRead: model.markGuildRead,
                mute: { guild, duration in
                    model.setGuildMute(
                        true,
                        until: duration.endDate(),
                        for: guild
                    )
                },
                unmute: { guild in
                    model.setGuildMute(false, until: nil, for: guild)
                },
                setNotificationLevel: { guild, level in
                    model.setGuildNotificationLevel(level, for: guild)
                },
                setNotificationToggle: { guild, toggle, isEnabled in
                    model.setGuildNotificationToggle(
                        toggle,
                        isEnabled: isEnabled,
                        for: guild
                    )
                }
            )
        )
    }
}

/// Keeps servers available without dedicating a permanent column to accounts
/// that spend most of their time in direct messages. The title itself is the
/// switcher, so the sidebar gains space without adding another toolbar button.
struct SidebarServerSwitcher: View {
    let model: AppModel
    let selectedGuild: Guild?
    let width: CGFloat
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Group {
                if width >= 108 {
                    HStack(spacing: 7) {
                        switcherIcon

                        Text(displayName)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Image(systemName: "chevron.up.chevron.down")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.secondary)
                    }
                } else {
                    switcherIcon
                        .frame(maxWidth: .infinity)
                }
            }
            .font(.system(
                size: InterfaceTypographyMetrics.interfaceTextSize,
                weight: .semibold
            ))
            .padding(.horizontal, 9)
            .frame(width: width, height: 28)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .glassEffect(
            .regular.tint(.white.opacity(0.04)).interactive(),
            in: Capsule()
        )
        .help("Switch between Direct Messages and servers")
        .accessibilityLabel("Current space: \(displayName)")
        .accessibilityHint("Shows Direct Messages and servers")
        .popover(isPresented: $isPresented) {
            ServerSwitcherPopover(
                items: model.serverRailPresentation.items,
                home: model.serverRailPresentation.home,
                selectHome: {
                    isPresented = false
                    model.selectGuild(nil)
                },
                selectGuild: { guildID in
                    isPresented = false
                    model.selectGuild(guildID)
                },
                contextMenuActions: contextMenuActions
            )
        }
    }

    @ViewBuilder
    private var switcherIcon: some View {
        if let selectedGuild {
            GuildIconView(
                name: displayName,
                iconURL: selectedGuild.iconURL,
                size: 18,
                cornerRadius: 5,
                animates: false
            )
        } else {
            Image(systemName: "message.fill")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(SakuraCordAccentColor.color)
                .frame(width: 18, height: 18)
        }
    }

    private var displayName: String {
        guard let selectedGuild else { return "Messages" }
        return selectedGuild.name.isEmpty ? "Unnamed Server" : selectedGuild.name
    }

    private var contextMenuActions: ServerRailContextMenuActions {
        ServerRailContextMenuActions(
            markRead: model.markGuildRead,
            mute: { guild, duration in
                model.setGuildMute(
                    true,
                    until: duration.endDate(),
                    for: guild
                )
            },
            unmute: { guild in
                model.setGuildMute(false, until: nil, for: guild)
            },
            setNotificationLevel: { guild, level in
                model.setGuildNotificationLevel(level, for: guild)
            },
            setNotificationToggle: { guild, toggle, isEnabled in
                model.setGuildNotificationToggle(
                    toggle,
                    isEnabled: isEnabled,
                    for: guild
                )
            }
        )
    }
}

private struct ServerSwitcherPopover: View {
    let items: [ServerRailPresentationItem]
    let home: ServerRailHomeEntry
    let selectHome: () -> Void
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    @State private var query = ""

    var body: some View {
        VStack(spacing: 0) {
            searchField
            Divider()

            ScrollView {
                LazyVStack(spacing: 4) {
                    if homeMatchesQuery {
                        ServerSwitcherHomeRow(
                            home: home,
                            action: selectHome
                        )
                    }

                    if homeMatchesQuery, hasServerMatches {
                        Divider()
                            .padding(.vertical, 5)
                    }

                    ForEach(items) { item in
                        switch item {
                        case .guild(let entry):
                            if entryMatchesQuery(entry) {
                                ServerSwitcherGuildRow(
                                    entry: entry,
                                    contextMenuActions: contextMenuActions,
                                    action: { selectGuild(entry.id) }
                                )
                            }
                        case .folder(let folder):
                            let matchingEntries = folder.guildEntries.filter(
                                entryMatchesQuery
                            )
                            if !matchingEntries.isEmpty {
                                if let folderName = folder.folder.name,
                                   !folderName.isEmpty
                                {
                                    Text(folderName)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(.secondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.top, 7)
                                }

                                ForEach(matchingEntries) { entry in
                                    ServerSwitcherGuildRow(
                                        entry: entry,
                                        contextMenuActions: contextMenuActions,
                                        action: { selectGuild(entry.id) }
                                    )
                                }
                            }
                        }
                    }

                    if !homeMatchesQuery, !hasServerMatches {
                        ContentUnavailableView.search(text: query)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 56)
                    }
                }
                .padding(8)
            }
            .scrollIndicators(.hidden)
        }
        .frame(width: 320, height: popoverHeight)
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Find a server", text: $query)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 11)
        .frame(height: 36)
        .background(
            Color.primary.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .padding(10)
    }

    private var normalizedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var homeMatchesQuery: Bool {
        normalizedQuery.isEmpty
            || "direct messages".localizedCaseInsensitiveContains(normalizedQuery)
            || "messages".localizedCaseInsensitiveContains(normalizedQuery)
    }

    private var hasServerMatches: Bool {
        serverMatchCount > 0
    }

    private var serverMatchCount: Int {
        items.reduce(into: 0) { count, item in
            switch item {
            case .guild(let entry):
                if entryMatchesQuery(entry) {
                    count += 1
                }
            case .folder(let folder):
                count += folder.guildEntries.count(where: entryMatchesQuery)
            }
        }
    }

    private var visibleFolderHeaderCount: Int {
        items.count { item in
            guard case .folder(let folder) = item,
                  let name = folder.folder.name,
                  !name.isEmpty
            else { return false }
            return folder.guildEntries.contains(where: entryMatchesQuery)
        }
    }

    private var popoverHeight: CGFloat {
        let visibleRows = serverMatchCount + (homeMatchesQuery ? 1 : 0)
        guard visibleRows > 0 else { return 220 }

        let searchAreaHeight: CGFloat = 57
        let rowHeight: CGFloat = 48
        let folderHeaderHeight: CGFloat = 25
        let dividerHeight: CGFloat = homeMatchesQuery && hasServerMatches ? 11 : 0
        let contentInsets: CGFloat = 16
        return min(
            440,
            searchAreaHeight
                + CGFloat(visibleRows) * rowHeight
                + CGFloat(visibleFolderHeaderCount) * folderHeaderHeight
                + dividerHeight
                + contentInsets
        )
    }

    private func entryMatchesQuery(_ entry: ServerRailGuildEntry) -> Bool {
        guard !normalizedQuery.isEmpty else { return true }
        guard let name = entry.presentation?.guild.name else { return false }
        return name.localizedCaseInsensitiveContains(normalizedQuery)
    }
}

private struct ServerSwitcherHomeRow: View {
    let home: ServerRailHomeEntry
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: "message.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(home.isSelected ? .white : SakuraCordAccentColor.color)
                    .frame(width: 32, height: 32)
                    .background(
                        home.isSelected
                            ? SakuraCordAccentColor.color
                            : Color.secondary.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
                    )

                Text("Direct Messages")
                    .font(.body.weight(.medium))
                    .frame(maxWidth: .infinity, alignment: .leading)

                notificationAccessory(
                    mentionCount: home.mentionCount,
                    isUnread: home.isUnread,
                    isSelected: home.isSelected
                )
            }
            .padding(.horizontal, 9)
            .frame(height: 44)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .accessibilityValue(notificationAccessibilityValue(
            mentionCount: home.mentionCount,
            isUnread: home.isUnread
        ))
    }

    private var rowBackground: some ShapeStyle {
        if home.isSelected {
            return AnyShapeStyle(SakuraCordAccentColor.color.opacity(0.16))
        }
        if isHovering {
            return AnyShapeStyle(Color.primary.opacity(0.06))
        }
        return AnyShapeStyle(Color.clear)
    }
}

private struct ServerSwitcherGuildRow: View {
    let entry: ServerRailGuildEntry
    let contextMenuActions: ServerRailContextMenuActions
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        if let presentation = entry.presentation {
            let guild = presentation.guild
            let displayName = guild.name.isEmpty ? "Unnamed Server" : guild.name

            Button(action: action) {
                HStack(spacing: 11) {
                    GuildIconView(
                        name: displayName,
                        iconURL: guild.iconURL,
                        size: 32,
                        cornerRadius: 9,
                        animates: isHovering
                    )

                    Text(displayName)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    notificationAccessory(
                        mentionCount: guild.mentionCount,
                        isUnread: guild.unreadCount > 0,
                        isSelected: entry.isSelected
                    )
                }
                .padding(.horizontal, 9)
                .frame(height: 44)
                .background(rowBackground)
                .contentShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
            .buttonStyle(.plain)
            .overlay {
                ServerContextMenuBridge(
                    isUnread: guild.unreadCount > 0,
                    isMutationPending: presentation.isNotificationMutationPending,
                    notificationSettings: presentation.notificationSettings,
                    markRead: { contextMenuActions.markRead(guild.id) },
                    mute: { contextMenuActions.mute(guild, $0) },
                    unmute: { contextMenuActions.unmute(guild) },
                    setNotificationLevel: {
                        contextMenuActions.setNotificationLevel(guild, $0)
                    },
                    setNotificationToggle: { toggle, isEnabled in
                        contextMenuActions.setNotificationToggle(
                            guild,
                            toggle,
                            isEnabled
                        )
                    },
                    copyServerID: {
                        ChannelContextMenuValue.copy(guild.id.description)
                    }
                )
            }
            .onHover { isHovering = $0 }
            .accessibilityLabel(displayName)
            .accessibilityValue(notificationAccessibilityValue(
                mentionCount: guild.mentionCount,
                isUnread: guild.unreadCount > 0
            ))
        }
    }

    private var rowBackground: some ShapeStyle {
        if entry.isSelected {
            return AnyShapeStyle(SakuraCordAccentColor.color.opacity(0.16))
        }
        if isHovering {
            return AnyShapeStyle(Color.primary.opacity(0.06))
        }
        return AnyShapeStyle(Color.clear)
    }
}

@ViewBuilder
private func notificationAccessory(
    mentionCount: Int,
    isUnread: Bool,
    isSelected: Bool
) -> some View {
    if mentionCount > 0 {
        Text(mentionCount, format: .number)
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .frame(minWidth: 20, minHeight: 18)
            .background(.red, in: Capsule())
    } else if isSelected {
        Image(systemName: "checkmark")
            .font(.caption.weight(.bold))
            .foregroundStyle(SakuraCordAccentColor.color)
            .frame(width: 20)
    } else if isUnread {
        Circle()
            .fill(.primary)
            .frame(width: 7, height: 7)
            .frame(width: 20)
    }
}

private func notificationAccessibilityValue(
    mentionCount: Int,
    isUnread: Bool
) -> String {
    if mentionCount > 0 {
        return "\(mentionCount) unread mentions"
    }
    return isUnread ? "Unread" : ""
}

struct ServerRailView: View {
    let items: [ServerRailPresentationItem]
    let home: ServerRailHomeEntry
    let selectHome: () -> Void
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    @State private var folderLayoutRevision = 0

    var body: some View {
        ScrollView {
            // Expanded folders make rail rows variable-height. Lazy layout
            // corrects its content estimate while reverse-scrolling, which
            // disrupts AppKit's elastic rebound at the top boundary.
            VStack(spacing: 10) {
                HomeRailButton(
                    home: home,
                    action: selectHome
                )

                Divider().padding(.horizontal, 12)

                ForEach(items) { item in
                    ServerRailItemView(
                        item: item,
                        selectGuild: selectGuild,
                        contextMenuActions: contextMenuActions,
                        folderExpansionChanged: {
                            folderLayoutRevision &+= 1
                        }
                    )
                }
            }
            .padding(.bottom, 12)
            .animation(ServerRailAnimations.folderExpansion, value: folderLayoutRevision)
        }
        .scrollIndicators(.hidden)
        .background {
            ScrollInputPerformanceProbeAttachment(surface: .serverList)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .frame(width: ChatChromeMetrics.serverRailWidth)
        .overlayPreferenceValue(ServerRailHoverPreferenceKey.self) { hoverItem in
            GeometryReader { proxy in
                if let hoverItem {
                    ServerRailHoverLabel(name: hoverItem.name)
                        .offset(
                            x: ChatChromeMetrics.serverRailWidth + 7,
                            y: proxy[hoverItem.bounds].midY - 16
                        )
                }
            }
            .allowsHitTesting(false)
        }
        .zIndex(200)
    }
}

struct ServerRailContextMenuActions {
    let markRead: (GuildID) -> Void
    let mute: (Guild, ChannelMuteDuration) -> Void
    let unmute: (Guild) -> Void
    let setNotificationLevel: (Guild, MessageNotificationLevel) -> Void
    let setNotificationToggle: (Guild, GuildNotificationToggle, Bool) -> Void
}

private struct ServerRailItemView: View {
    let item: ServerRailPresentationItem
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions
    let folderExpansionChanged: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            switch item {
            case .guild(let entry):
                ServerRailGuildItemView(
                    entry: entry,
                    selectGuild: selectGuild,
                    contextMenuActions: contextMenuActions
                )
            case .folder(let entry):
                ServerFolderRailView(
                    entry: entry,
                    selectGuild: selectGuild,
                    contextMenuActions: contextMenuActions,
                    expansionChanged: folderExpansionChanged
                )
            }
        }
    }
}

struct ServerRailGuildItemView: View {
    let entry: ServerRailGuildEntry
    let selectGuild: (GuildID?) -> Void
    let contextMenuActions: ServerRailContextMenuActions

    var body: some View {
        if let presentation = entry.presentation {
            GuildRailButton(
                presentation: presentation,
                isSelected: entry.isSelected,
                contextMenuActions: contextMenuActions
            ) {
                selectGuild(entry.id)
            }
        }
    }
}

enum ServerRailAnimations {
    static let folderExpansion = Animation.spring(duration: ChatAnimationSpeed.scaled(0.38), bounce: 0.08)
}

struct GuildRailButton: View {
    let presentation: ServerRailGuildPresentation
    let isSelected: Bool
    let contextMenuActions: ServerRailContextMenuActions
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        let guild = presentation.guild
        let displayName = guild.name.isEmpty ? "Unnamed Server" : guild.name

        HStack(spacing: 5) {
            ServerRailSelectionIndicator(
                isSelected: isSelected,
                isHovering: isHovering,
                hasNotification: guild.unreadCount > 0
            )
            Button(action: action) {
                GuildIconView(
                    name: displayName,
                    iconURL: guild.iconURL,
                    size: 44,
                    cornerRadius: 14,
                    animates: isHovering
                )
                    .overlay(alignment: .bottomTrailing) {
                        if guild.mentionCount > 0 {
                            Text(guild.mentionCount, format: .number)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(.red, in: Capsule())
                                .offset(x: 4, y: 4)
                        }
                    }
            }
            .buttonStyle(.plain)
            .overlay {
                ServerContextMenuBridge(
                    isUnread: guild.unreadCount > 0,
                    isMutationPending:
                        presentation.isNotificationMutationPending,
                    notificationSettings: presentation.notificationSettings,
                    markRead: { contextMenuActions.markRead(guild.id) },
                    mute: { contextMenuActions.mute(guild, $0) },
                    unmute: { contextMenuActions.unmute(guild) },
                    setNotificationLevel: {
                        contextMenuActions.setNotificationLevel(guild, $0)
                    },
                    setNotificationToggle: { toggle, isEnabled in
                        contextMenuActions.setNotificationToggle(
                            guild,
                            toggle,
                            isEnabled
                        )
                    },
                    copyServerID: {
                        ChannelContextMenuValue.copy(guild.id.description)
                    }
                )
            }
            .accessibilityLabel(displayName)
            .accessibilityValue(
                guild.mentionCount > 0
                    ? "\(guild.mentionCount) unread mentions"
                    : (guild.unreadCount > 0 ? "Unread" : "")
            )
            .help(displayName)
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: 46, alignment: .topLeading)
        .contentShape(Rectangle())
        .anchorPreference(key: ServerRailHoverPreferenceKey.self, value: .bounds) { bounds in
            isHovering ? ServerRailHoverItem(name: displayName, bounds: bounds) : nil
        }
        .onHover { isHovering = $0 }
        .animation(.snappy(duration: ChatAnimationSpeed.scaled(0.18)), value: isHovering)
    }
}

private struct ServerRailHoverLabel: View {
    let name: String

    var body: some View {
        Text(name)
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 11)
            .frame(height: 32)
            .glassEffect(.regular, in: Capsule())
            .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .leading)))
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}

struct ServerRailHoverItem {
    let name: String
    let bounds: Anchor<CGRect>
}

struct ServerRailHoverPreferenceKey: PreferenceKey {
    static let defaultValue: ServerRailHoverItem? = nil

    static func reduce(value: inout ServerRailHoverItem?, nextValue: () -> ServerRailHoverItem?) {
        value = nextValue() ?? value
    }
}

private struct HomeRailButton: View {
    let home: ServerRailHomeEntry
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 5) {
            ServerRailSelectionIndicator(
                isSelected: home.isSelected,
                isHovering: isHovering,
                hasNotification: home.isUnread
            )
            Button(action: action) {
                Image(systemName: "message.fill")
                    .font(.title2)
                    .frame(width: 44, height: 44)
                    .background(
                        home.isSelected
                            ? SakuraCordAccentColor.color
                            : Color.secondary.opacity(0.16),
                        in: ConcentricRectangle(cornerRadius: 14, style: .continuous)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if home.mentionCount > 0 {
                            Text(home.mentionCount, format: .number)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 5)
                                .frame(minWidth: 18, minHeight: 18)
                                .background(.red, in: Capsule())
                                .offset(x: 4, y: 4)
                        }
                    }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Direct Messages")
            .accessibilityValue(
                home.mentionCount > 0
                    ? "\(home.mentionCount) unread mentions"
                    : (home.isUnread ? "Unread" : "")
            )
        }
        .frame(width: ChatChromeMetrics.serverRailWidth, height: 46, alignment: .leading)
        .contentShape(Rectangle())
        .onHover { isHovering = $0 }
        .help("Direct Messages")
    }
}

struct ServerRailSelectionIndicator: View {
    let isSelected: Bool
    let isHovering: Bool
    let hasNotification: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Capsule()
            .fill(colorScheme == .dark ? Color.white : Color.black)
            .frame(width: 4, height: indicatorHeight)
            .opacity(indicatorHeight == 0 ? 0 : 1)
            .frame(width: 7, height: 40)
            .animation(.snappy(duration: ChatAnimationSpeed.scaled(0.2)), value: indicatorHeight)
    }

    private var indicatorHeight: CGFloat {
        if isSelected {
            return 36
        }
        if isHovering {
            return 20
        }
        if hasNotification {
            return 8
        }
        return 0
    }
}
