import Foundation

/// Содержимое страницы About: тексты и ссылки. Правится вручную, остальной код трогать не нужно.
/// Порядок на странице: значок приложения, вступление, название, версия с меткой, продолжение, кнопка обновлений,
/// «Inspired by this video» и ссылки в одну строку. Вступление и продолжение показываются серым.
enum AboutContent {
    /// Вступление под значком: каждая строка списка это строка на экране (переносы расставлены вручную).
    static let intro = [
        "Sometimes I catch myself feeling that time is flying by",
        "and I can't remember what I've been doing.",
        "Then only one question comes to mind:",
    ]

    /// Название приложения.
    static let title = "what was that!?"

    /// Мелкая метка справа от версии (nil — не показывать).
    static let tag: String? = "[100% vibe coding]"

    /// Текст под названием и версией, в одну строку.
    static let outro = "This app helps you capture the main events of your days"

    /// Строка над ссылками: серый текст и ссылка на видео, которое вдохновило приложение.
    static let inspiredText = "Inspired by"
    static let inspiredLinkTitle = "this video"
    static let inspiredURL = "https://www.youtube.com/watch?v=Et_QEhwwmec&t=11s"

    /// Ссылки в одну строку, слева направо: подпись и адрес. Если адрес nil, подпись показывается серым текстом без
    /// перехода (когда адрес появится, станет обычной ссылкой).
    static let links: [(title: String, url: String?)] = [
        ("mlmlml.ru", "https://mlmlml.ru"),
        ("GitHub", "https://github.com/lukyanetc/what-was-that"),
    ]
}
