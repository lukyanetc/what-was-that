import SwiftUI

/// Окно настроек внешнего вида.
struct SettingsView: View {
    @Bindable var appearance: Appearance

    private static let datePresets = ["DD ddd", "ddd DD", "DD.MM", "DD.MM.YYYY", "MM/DD/YYYY", "YYYY-MM-DD"]
    private static let monthPresets = ["MMMM YYYY", "MMMM", "MMM YY", "YYYY-MM"]

    var body: some View {
        Form {
            Section("Текст") {
                ColorPicker("Цвет", selection: $appearance.color, supportsOpacity: false)
                Toggle("Подстраивать под обои", isOn: $appearance.adapts)
                Slider(value: $appearance.textOpacity, in: 0.2...1) { Text("Прозрачность") }
                Picker("Шрифт", selection: $appearance.fontName) {
                    Text("Системный").tag(Appearance.systemFont)
                    ForEach(Appearance.fonts, id: \.self) { Text($0).tag($0) }
                }
                Slider(value: $appearance.fontSize, in: Appearance.fontSizeRange, step: 1) {
                    Text("Размер шрифта: \(Int(appearance.fontSize))")
                }
                Toggle("Линия между датой и записью", isOn: $appearance.showsDivider)
                Toggle("Заглавные буквы", isOn: $appearance.uppercase)
                Text(appearance.isMeasured
                     ? "Обои под лентой: \(appearance.luminance < 0.5 ? "тёмные" : "светлые") (\(Int(appearance.luminance * 100))%)"
                     : "Обои не удалось измерить, ориентируюсь на тему системы")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Формат даты") {
                formatField("Формат", text: $appearance.dateFormat, presets: Self.datePresets)
                LabeledContent("Пример") { Text(appearance.dayText(.now)) }
                Text("Как в moment.js, без времени: YYYY YY MMMM MMM MM M Do DD D dddd ddd dd E Q W w DDD. Текст в [скобках] выводится как есть.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Section("Месяц") {
                Toggle("Показывать заголовки месяцев", isOn: $appearance.showsMonth)
                if appearance.showsMonth {
                    formatField("Формат", text: $appearance.monthFormat, presets: Self.monthPresets)
                    Toggle("Жирный шрифт", isOn: $appearance.monthBold)
                    LabeledContent("Пример") { Text(appearance.monthText(.now)).bold(appearance.monthBold) }
                }
            }
            Section("Записи") {
                Toggle("Несколько строк в дне (Shift+Enter)", isOn: $appearance.allowsMultiline)
            }
            Section("Неделя") {
                Toggle("Номер недели у понедельника", isOn: $appearance.showsWeekNumber)
                Toggle("Увеличенный отступ между неделями", isOn: $appearance.weekGap)
            }
            Section("Окно") {
                Slider(value: $appearance.width, in: Appearance.widthRange, step: 10) { Text("Ширина") }
                Slider(value: $appearance.edgeFade, in: 0...150, step: 5) { Text("Затухание у краёв") }
            }
            Section("Линия выделения сегодняшнего дня") {
                ColorPicker("Цвет и прозрачность",
                            selection: Binding(get: { appearance.highlightColor }, set: { appearance.highlight = $0 }))
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
    }

    /// Поле формата и меню готовых шаблонов.
    private func formatField(_ title: String, text: Binding<String>, presets: [String]) -> some View {
        HStack {
            TextField(title, text: text)
            Menu("Шаблоны") {
                ForEach(presets, id: \.self) { preset in
                    Button("\(preset)  →  \(MomentFormat.string(from: .now, pattern: preset))") { text.wrappedValue = preset }
                }
            }
            .fixedSize()
        }
    }
}
