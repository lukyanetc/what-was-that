import SwiftUI
import UniformTypeIdentifiers

/// Список календарей в настройках по аккаунтам (iCloud, Google и так далее): галочка и название цветом календаря.
/// Порядок внутри аккаунта меняется перетаскиванием строки: выше в списке значит выше в ленте и побеждает при дубликатах.
/// Это отдельный вид со своим состоянием: линия-«прицел» при перетаскивании обновляет только его, а не всё окно
/// настроек (иначе перетаскивание подтормаживало).
struct CalendarListView: View {
    let appearance: Appearance
    let events: CalendarEvents
    /// Календарь, который сейчас тащат, и строка, над которой он висит.
    @State private var draggedID: String?
    @State private var dropTarget: String?

    private typealias CalendarItem = (id: String, title: String, source: String, color: Color)

    /// Календари в порядке приоритета (порядок в настройках); новые, которых в порядке ещё нет, идут в конце.
    private var orderedCalendars: [CalendarItem] {
        let order = appearance.eventCalendarOrder
        return events.calendars.enumerated().sorted { a, b in
            (order.firstIndex(of: a.element.id) ?? order.count + a.offset)
                < (order.firstIndex(of: b.element.id) ?? order.count + b.offset)
        }.map(\.element)
    }

    /// Календари по аккаунтам: аккаунты по порядку первого календаря в приоритете.
    private var groups: [(source: String, items: [CalendarItem])] {
        var sources: [String] = []
        var bySource: [String: [CalendarItem]] = [:]
        for calendar in orderedCalendars {
            if bySource[calendar.source] == nil { sources.append(calendar.source) }
            bySource[calendar.source, default: []].append(calendar)
        }
        return sources.compactMap { source in bySource[source].map { (source, $0) } }
    }

    /// Переносит календарь на место другого в том же аккаунте: перетаскивание вниз ставит его после, вверх до.
    /// Общий порядок приоритета меняется только на местах, которые занимал этот аккаунт.
    private func move(_ dragged: String, onto target: String, among siblings: [String]) {
        guard let from = siblings.firstIndex(of: dragged), let to = siblings.firstIndex(of: target), from != to else { return }
        var group = siblings
        group.remove(at: from)
        group.insert(dragged, at: to)
        var all = orderedCalendars.map(\.id)
        let slots = all.indices.filter { siblings.contains(all[$0]) }
        for (slot, id) in zip(slots, group) { all[slot] = id }
        appearance.eventCalendarOrder = all
    }

    /// С какого края строки рисовать линию «сюда упадёт»: тащим вниз, значит календарь встанет после строки (линия снизу),
    /// вверх, значит до неё (линия сверху). nil, если линия не нужна.
    private func lineEdge(for id: String, siblings: [String]) -> Alignment? {
        guard dropTarget == id, let dragged = draggedID, dragged != id,
              let from = siblings.firstIndex(of: dragged), let to = siblings.firstIndex(of: id) else { return nil }
        return from < to ? .bottom : .top
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(groups, id: \.source) { group in
                VStack(alignment: .leading, spacing: 2) {
                    Text(group.source).bold()
                    ForEach(group.items, id: \.id) { calendar in
                        row(calendar, siblings: group.items.map(\.id))
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(.quaternary))
    }

    private func row(_ calendar: CalendarItem, siblings: [String]) -> some View {
        let edge = lineEdge(for: calendar.id, siblings: siblings)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(
                get: { appearance.eventCalendarIDs.contains(calendar.id) },
                set: { isOn in
                    if isOn { appearance.eventCalendarIDs.insert(calendar.id) }
                    else { appearance.eventCalendarIDs.remove(calendar.id) }
                })
            ) {
                Text(calendar.title).bold().foregroundStyle(calendar.color)
            }
            .toggleStyle(.checkbox)
            Spacer(minLength: 0)
            Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
        }
        .padding(.vertical, 3)
        .padding(.horizontal, 4)
        // Полоска-прицел на границе между строками: показывает, куда встанет тащимый календарь.
        .overlay(alignment: edge ?? .top) {
            if edge != nil {
                Capsule().fill(Color.accentColor).frame(height: 2).offset(y: edge == .bottom ? 2 : -2)
            }
        }
        .contentShape(Rectangle())
        .onDrag {
            draggedID = calendar.id
            return NSItemProvider(object: calendar.id as NSString)
        }
        .onDrop(of: [.text], delegate: RowDropDelegate(
            id: calendar.id, siblings: siblings, dragged: $draggedID, target: $dropTarget,
            move: { dragged, target, siblings in move(dragged, onto: target, among: siblings) }))
    }
}

/// Приём перетаскивания на строку списка: только внутри одного аккаунта; следит, над какой строкой висит курсор.
private struct RowDropDelegate: DropDelegate {
    let id: String
    let siblings: [String]
    @Binding var dragged: String?
    @Binding var target: String?
    let move: (String, String, [String]) -> Void

    func validateDrop(info: DropInfo) -> Bool {
        guard let dragged else { return false }
        return siblings.contains(dragged)
    }

    func dropEntered(info: DropInfo) { target = id }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func dropExited(info: DropInfo) { if target == id { target = nil } }

    func performDrop(info: DropInfo) -> Bool {
        defer { dragged = nil; target = nil }
        // Содержимое перетаскивания забираем (его значение нам не нужно, мы знаем календарь по `dragged`): пока
        // получатель не заберёт данные, система держит картинку перетаскиваемой строки на экране ещё около секунды.
        if let provider = info.itemProviders(for: [.text]).first {
            _ = provider.loadObject(ofClass: NSString.self) { _, _ in }
        }
        guard let dragged, siblings.contains(dragged) else { return false }
        move(dragged, id, siblings)
        return true
    }
}
