import EventKit
import Foundation

/// Shows the next calendar event. Off until the user turns it on from the
/// right-click menu, which is when macOS asks for calendar access.
final class CalendarMonitor {
    private let model: IslandModel
    private let store = EKEventStore()
    private static let key = "calendarEnabled"

    var enabled: Bool { UserDefaults.standard.bool(forKey: Self.key) }

    init(model: IslandModel) {
        self.model = model
        let timer = Timer(timeInterval: 30, repeats: true) { [weak self] _ in self?.refresh() }
        RunLoop.main.add(timer, forMode: .common)
        refresh()
    }

    func setEnabled(_ on: Bool) {
        UserDefaults.standard.set(on, forKey: Self.key)
        guard on else {
            refresh()
            return
        }
        store.requestFullAccessToEvents { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func refresh() {
        guard enabled, EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            model.nextEvent = nil
            model.eventImminent = false
            return
        }
        let now = Date()
        // From two minutes ago, so an event that just started stays visible briefly.
        let predicate = store.predicateForEvents(withStart: now.addingTimeInterval(-120),
                                                 end: now.addingTimeInterval(2 * 3600), calendars: nil)
        let next = store.events(matching: predicate)
            .filter { !$0.isAllDay && $0.startDate > now.addingTimeInterval(-120) }
            .min { $0.startDate < $1.startDate }

        let event = next.map { UpcomingEvent(title: $0.title ?? "Etkinlik", start: $0.startDate) }
        if model.nextEvent != event { model.nextEvent = event }
        let imminent = event.map { $0.start.timeIntervalSince(now) <= 600 } ?? false
        if model.eventImminent != imminent { model.eventImminent = imminent }
    }
}
