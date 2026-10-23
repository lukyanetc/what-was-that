import SwiftUI
import UniformTypeIdentifiers

/// List of calendars in settings grouped by account (iCloud, Google and so on): a checkbox and the name in the calendar's color.
/// The order within an account changes by dragging a row: higher in the list means higher in the feed and wins on duplicates.
/// This is a separate view with its own state: the "crosshair" line during dragging updates only it, not the whole settings
/// window (otherwise dragging lagged).
struct CalendarListView: View {
    let appearance: Appearance
    let events: CalendarEvents
    /// The calendar being dragged and the row it hovers over.
    @State private var draggedID: String?
    @State private var dropTarget: String?

    private typealias CalendarItem = (id: String, title: String, source: String, color: Color)

    /// Calendars in priority order (the order in settings); new ones not yet in the order go last.
    private var orderedCalendars: [CalendarItem] {
        let order = appearance.eventCalendarOrder
        return events.calendars.enumerated().sorted { a, b in
            (order.firstIndex(of: a.element.id) ?? order.count + a.offset)
                < (order.firstIndex(of: b.element.id) ?? order.count + b.offset)
        }.map(\.element)
    }

    /// Calendars by account: accounts ordered by their first calendar in the priority.
    private var groups: [(source: String, items: [CalendarItem])] {
        var sources: [String] = []
        var bySource: [String: [CalendarItem]] = [:]
        for calendar in orderedCalendars {
            if bySource[calendar.source] == nil { sources.append(calendar.source) }
            bySource[calendar.source, default: []].append(calendar)
        }
        return sources.compactMap { source in bySource[source].map { (source, $0) } }
    }

    /// Moves a calendar to the place of another one in the same account: dragging down puts it after, up puts it before.
    /// The overall priority order changes only at the positions this account occupied.
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

    /// Which edge of the row to draw the "drops here" line on: dragging down means the calendar lands after the row (line at the bottom),
    /// up means before it (line at the top). nil if no line is needed.
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
        // A crosshair strip on the boundary between rows: shows where the dragged calendar will land.
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

/// Drop target on a list row: only within one account; tracks which row the cursor hovers over.
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
        // We take the drag content (its value is not needed, we know the calendar from `dragged`): until
        // the receiver takes the data, the system keeps the image of the dragged row on screen for about another second.
        if let provider = info.itemProviders(for: [.text]).first {
            _ = provider.loadObject(ofClass: NSString.self) { _, _ in }
        }
        guard let dragged, siblings.contains(dragged) else { return false }
        move(dragged, id, siblings)
        return true
    }
}
