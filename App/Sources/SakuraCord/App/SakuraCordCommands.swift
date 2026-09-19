import AppKit
import SwiftUI

struct SakuraCordCommands: Commands {
    let model: AppModel
    let updateController: AppUpdateController

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("About SakuraCord") {
                NSApp.orderFrontStandardAboutPanel(options: [
                    .applicationVersion:
                        AboutVersionInformation().semanticVersionDisplay,
                    .version: "",
                ])
            }

            Divider()

            CheckForUpdatesCommand(updateController: updateController)
        }

        CommandGroup(replacing: .sidebar) {
            ShortcutCommandButton(
                action: .toggleChannelSidebar,
                model: model
            )
        }

        CommandMenu("Navigate") {
            ShortcutCommandButton(action: .quickSwitch, model: model)
            ShortcutCommandButton(action: .messageSearch, model: model)

            Divider()

            ShortcutCommandButton(action: .previousConversation, model: model)
            ShortcutCommandButton(action: .nextConversation, model: model)
            ShortcutCommandButton(action: .previousUnread, model: model)
            ShortcutCommandButton(action: .nextUnread, model: model)
            ShortcutCommandButton(action: .currentCall, model: model)

            Divider()

            Button("Direct Messages") {
                model.selectGuild(nil)
            }

            // Command numbers open the direct messages in list order; adding
            // Option switches to the servers in rail order.
            ForEach(1 ... 9, id: \.self) { shortcutNumber in
                Button("Conversation \(shortcutNumber)") {
                    model.navigateToConversationShortcut(shortcutNumber)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(shortcutNumber)))
                )
            }

            Divider()

            ForEach(1 ... 9, id: \.self) { shortcutNumber in
                Button("Server \(shortcutNumber)") {
                    model.navigateToServerShortcut(shortcutNumber)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(shortcutNumber))),
                    modifiers: [.command, .option]
                )
            }

            Divider()

            ShortcutCommandButton(action: .toggleMemberList, model: model)
        }

        CommandMenu("Music") {
            // The only way in before anything is playing: the sidebar bar
            // appears with a track, and there is no track until someone has
            // started one here.
            Button("YouTube Music") {
                model.music.presentation =
                    model.music.presentation == nil ? .browse : nil
            }
            .keyboardShortcut("m", modifiers: [.command, .shift])

            Button(model.showsLyrics ? "Hide Lyrics" : "Show Lyrics") {
                model.showsLyrics.toggle()
            }
            .keyboardShortcut("l", modifiers: [.command, .option])
            .disabled(!model.music.state.hasTrack)

            Divider()

            Toggle(
                "Romanized Lyrics",
                isOn: Binding(
                    get: { model.music.lyrics.showsRomanization },
                    set: { model.music.lyrics.setShowsRomanization($0) }
                )
            )
            Toggle(
                "Translated Lyrics",
                isOn: Binding(
                    get: { model.music.lyrics.showsTranslation },
                    set: { model.music.lyrics.setShowsTranslation($0) }
                )
            )
            Picker(
                "Translation Language",
                selection: Binding(
                    get: { model.music.lyrics.translationLanguage },
                    set: { model.music.lyrics.setTranslationLanguage($0) }
                )
            ) {
                ForEach(LyricsTranslationLanguage.supported) { language in
                    Text(language.name).tag(language.code)
                }
            }
            .disabled(!model.music.lyrics.showsTranslation)

            Divider()

            // The feed belongs to the page and changes when YouTube rebuilds
            // it, which nothing here can be told about. Asking is the only
            // way to find out.
            Button("Refresh Feed") { model.music.refreshHome() }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(model.music.isLoadingHome)

            Divider()

            Button(model.music.state.isPlaying ? "Pause" : "Play") {
                model.music.playPause()
            }
            .disabled(!model.music.state.hasTrack)
            Button("Next Track") { model.music.next() }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(!model.music.state.hasTrack)
            Button("Previous Track") { model.music.previous() }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(!model.music.state.hasTrack)
        }

        CommandMenu("Message") {
            ShortcutCommandButton(action: .focusComposer, model: model)
            ShortcutCommandButton(action: .editLastMessage, model: model)
            ShortcutCommandButton(action: .reply, model: model)
            ShortcutCommandButton(action: .upload, model: model)

            Divider()

            ShortcutCommandButton(
                action: .searchCurrentConversation,
                model: model
            )
            ShortcutCommandButton(action: .markRead, model: model)
        }

        CommandMenu("Voice") {
            ShortcutCommandButton(action: .toggleMute, model: model)
            ShortcutCommandButton(action: .toggleDeafen, model: model)
            ShortcutCommandButton(action: .toggleCamera, model: model)
            ShortcutCommandButton(action: .toggleScreenShare, model: model)

            Divider()

            ShortcutCommandButton(action: .leaveCall, model: model)
        }
    }
}

private struct ShortcutCommandButton: View {
    let action: KeyboardShortcutAction
    let model: AppModel
    private let shortcuts = KeyboardShortcutSettingsStore.shared

    var body: some View {
        Button(action.title) {
            model.performKeyboardShortcutAction(action)
        }
        .disabled(!model.keyboardShortcutActionIsEnabled(action))
        .keyboardShortcut(
            action.registersMenuShortcut
                ? shortcuts.shortcut(for: action)?.swiftUIShortcut
                : nil
        )
    }
}

private struct CheckForUpdatesCommand: View {
    @ObservedObject var updateController: AppUpdateController

    var body: some View {
        Button("Check for Updates…") {
            updateController.checkForUpdates()
        }
        .disabled(!updateController.canCheckForUpdates)
        .help(updateController.availabilityDescription)
    }
}
