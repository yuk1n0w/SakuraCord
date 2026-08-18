import AppKit
import SakuraCordModels

/// Classic IRC nick colouring for group conversations.
///
/// A server has roles to colour a name by, but a group direct message has
/// nothing: every name paints the same label colour, so a busy group reads
/// as one voice. IRC clients solved this in the nineties by deriving a
/// colour from the nick itself, which is both instantly recognisable and
/// genuinely useful - you learn who is speaking before you read the name.
///
/// The colour comes from the account's identifier rather than its display
/// name, so it is stable: someone renaming themselves keeps the colour the
/// room already associates with them.
enum RetroNickPalette {
    /// Bright enough to read on the conversation's dark backdrop, and
    /// spaced around the wheel so neighbouring entries stay distinct. The
    /// hues are the familiar mIRC set rather than the app's own accent
    /// ramp, which is the point: they should feel borrowed from an older
    /// client.
    static let colors: [NSColor] = [
        NSColor(srgbRed: 0.98, green: 0.38, blue: 0.36, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.85, blue: 0.45, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.80, blue: 0.31, alpha: 1),
        NSColor(srgbRed: 0.42, green: 0.66, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.91, green: 0.47, blue: 0.90, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.86, blue: 0.87, alpha: 1),
        NSColor(srgbRed: 0.99, green: 0.62, blue: 0.35, alpha: 1),
        NSColor(srgbRed: 0.69, green: 0.57, blue: 0.99, alpha: 1),
        NSColor(srgbRed: 0.36, green: 0.82, blue: 0.70, alpha: 1),
        NSColor(srgbRed: 0.98, green: 0.55, blue: 0.68, alpha: 1)
    ]

    /// The same account always lands on the same colour, in this session and
    /// the next: the index is taken from the identifier's own bits rather
    /// than from anything ordering-dependent like the member list.
    static func color(for id: UserID) -> NSColor {
        // Snowflakes carry their timestamp in the high bits and the worker
        // and sequence counters in the low twenty-two, so the low bits vary
        // between accounts far more than the high ones do.
        let index = Int(id.rawValue % UInt64(colors.count))
        return colors[index]
    }
}
