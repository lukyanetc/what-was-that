import SwiftUI

/// Окно настроек внешнего вида.
struct SettingsView: View {
    @Bindable var appearance: Appearance

    private static let datePresets = ["DD ddd", "ddd DD", "DD.MM", "DD.MM.YYYY", "MM/DD/YYYY", "YYYY-MM-DD"]
    private static let monthPresets = ["MMMM YYYY", "MMMM", "MMM YY", "YYYY-MM"]

    var body: some View {
        Form {
            Section("Отрезок времени") {
                Picker("Показывать", selection: $appearance.viewKind) {
                    ForEach(ViewKind.allCases, id: \.self) { Text($0.title) }
                }
                .pickerStyle(.segmented)
            }
            Section("Мои отрезки") {
                ForEach(appearance.periods) { period in
                    periodRow(period.id)
                }
                HStack {
                    Button("Добавить отрезок") {
                        let today = Calendar.current.startOfDay(for: .now)
                        let end = Calendar.current.date(byAdding: .day, value: 6, to: today) ?? today
                        appearance.periods.append(Period(name: "", start: today, end: end))
                    }
                    Spacer()
                    Button("Удалить истекшие") {
                        appearance.periods.removeAll { $0.isExpired(on: .now) }
                    }
                    .disabled(!appearance.periods.contains { $0.isExpired(on: .now) })
                }
                Toggle("Показывать отрезки в ленте", isOn: $appearance.showsPeriodsInFeed)
                Toggle("Счётчик дней под названием", isOn: $appearance.showsPeriodCounter)
                Text("Режим «Период» показывает только дни самого длинного из идущих отрезков, короткие видны внутри него. В «Месяце» и «Неделе» отрезков нет, в «Ленте» их можно отключить.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
                Slider(value: $appearance.rowPadding, in: Appearance.rowPaddingRange, step: 1) {
                    Text("Расстояние между строками: \(Int(appearance.rowPadding * 2))")
                }
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

    /// Строка отрезка: название, начало, конец, удаление. Истёкшие приглушены и зачёркнуты.
    private func periodRow(_ id: UUID) -> some View {
        // Привязка по id, а не по индексу: после удаления строка ещё раз читает своё значение, и индекс
        // выходил бы за границы массива (падение).
        let period = Binding<Period>(
            get: { appearance.periods.first { $0.id == id } ?? Period(id: id, name: "", start: .now, end: .now) },
            set: { value in
                if let index = appearance.periods.firstIndex(where: { $0.id == id }) { appearance.periods[index] = value }
            })
        let isExpired = period.wrappedValue.isExpired(on: .now)
        return VStack(alignment: .leading) {
            TextField("Название", text: period.name)
            HStack {
                DatePicker("Начало", selection: Binding(
                    get: { period.wrappedValue.start },
                    set: {
                        period.wrappedValue.start = $0
                        // Конец не может быть раньше начала.
                        if period.wrappedValue.end < $0 { period.wrappedValue.end = $0 }
                    }), displayedComponents: .date)
                DatePicker("Конец", selection: period.end, in: period.wrappedValue.start..., displayedComponents: .date)
                Button("Удалить", systemImage: "trash") {
                    appearance.periods.removeAll { $0.id == id }
                }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
            }
            // Длинный период не помещается в окно: режим «Период» покажет вместо него обычную ленту.
            if !isExpired, appearance.estimatedHeight(of: period.wrappedValue)
                > appearance.periodRoom(screenHeight: Double(NSScreen.main?.frame.height ?? 0)) {
                Text("Не помещается в окно: режим «Период» покажет ленту")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .strikethrough(isExpired)
        .opacity(isExpired ? 0.5 : 1)
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
