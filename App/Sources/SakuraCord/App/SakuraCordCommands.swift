import SwiftUI

struct SakuraCordCommands: Commands {
    let model: AppModel
    let updateController: AppUpdateController

    var body: some Commands {
        CommandGroup(after: .appInfo) {
            CheckForUpdatesCommand(updateController: updateController)
        }

        CommandMenu("Navigate") {
            Button("Quick Switch…") {
                model.presentQuickSwitcher()
            }
            .keyboardShortcut("k")

            Button("Search Messages…") {
                model.presentMessageSearchFromCommand()
            }
            .keyboardShortcut("f")

            Divider()

            Button("Direct Messages") {
                model.navigateUsingShortcut(1)
            }
            .keyboardShortcut("1")

            ForEach(2 ... 9, id: \.self) { shortcutNumber in
                Button("Server \(shortcutNumber - 1)") {
                    model.navigateUsingShortcut(shortcutNumber)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(shortcutNumber)))
                )
            }

            Divider()

            ForEach(1 ... 9, id: \.self) { shortcutNumber in
                Button("Conversation \(shortcutNumber)") {
                    model.navigateToConversationShortcut(shortcutNumber)
                }
                .keyboardShortcut(
                    KeyEquivalent(Character(String(shortcutNumber))),
                    modifiers: [.command, .option]
                )
            }

            Divider()

            Button("Toggle Member Inspector") { NotificationCenter.default.post(name: .sakuracordToggleInspector, object: nil) }
                .keyboardShortcut("i", modifiers: [.command, .option])
            Button("Focus Composer") { NotificationCenter.default.post(name: .sakuracordFocusComposer, object: nil) }
                .keyboardShortcut("l", modifiers: [.command, .shift])

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
