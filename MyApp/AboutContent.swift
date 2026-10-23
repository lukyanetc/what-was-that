import Foundation

/// Content of the About page: texts and links. Edit by hand; no other code needs to change.
/// Page order: app icon, intro, title, version with tag, outro, update button,
/// "Inspired by this video" and a row of links. The intro and outro are shown in gray.
enum AboutContent {
    /// Intro under the icon: each list item is one line on screen (line breaks are placed by hand).
    static let intro = [
        "Sometimes I catch myself feeling that time is flying by",
        "and I can't remember what I've been doing.",
        "Then only one question comes to mind:",
    ]

    /// App title.
    static let title = "what was that!?"

    /// Small tag to the right of the version (nil hides it).
    static let tag: String? = "[100% vibe coding]"

    /// Text under the title and version, on one line.
    static let outro = "This app helps you capture the main events of your days"

    /// Line above the links: gray text and a link to the video that inspired the app.
    static let inspiredText = "Inspired by"
    static let inspiredLinkTitle = "this video"
    static let inspiredURL = "https://www.youtube.com/watch?v=Et_QEhwwmec&t=11s"

    /// Links in one row, left to right: title and address. If the address is nil, the title is shown as gray text without
    /// a link (once an address is added, it becomes a normal link).
    static let links: [(title: String, url: String?)] = [
        ("mlmlml.ru", "https://mlmlml.ru"),
        ("GitHub", "https://github.com/lukyanetc/what-was-that"),
    ]
}
