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

/// Shows the reminder that is due next, and a notice when one comes due.
/// Off until the user turns it on from the right-click menu.
final class ReminderMonitor {
    private let model: IslandModel
    private let store = EKEventStore()
    private var announced: Set<String> = []
    private var firstPass = true
    private static let key = "remindersEnabled"

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
        store.requestFullAccessToReminders { [weak self] _, _ in
            DispatchQueue.main.async { self?.refresh() }
        }
    }

    private func refresh() {
        guard enabled, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
            model.nextReminder = nil
            return
        }
        let now = Date()
        // Overdue ones from today stay visible; later than two hours away is not "next".
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: now.addingTimeInterval(-12 * 3600),
                                                              ending: now.addingTimeInterval(2 * 3600), calendars: nil)
        store.fetchReminders(matching: predicate) { [weak self] reminders in
            let due = (reminders ?? []).compactMap { reminder -> (id: String, title: String, date: Date)? in
                // Reminders with a day but no time are not timed alerts.
                guard let parts = reminder.dueDateComponents, parts.hour != nil,
                      let date = Calendar.current.date(from: parts) else { return nil }
                return (reminder.calendarItemIdentifier, reminder.title ?? "Anımsatıcı", date)
            }.sorted { $0.date < $1.date }

            DispatchQueue.main.async {
                guard let self else { return }
                let next = due.first.map { UpcomingEvent(title: $0.title, start: $0.date) }
                if self.model.nextReminder != next { self.model.nextReminder = next }

                for item in due where item.date <= Date() && !self.announced.contains(item.id) {
                    self.announced.insert(item.id)
                    // Ones already overdue at launch are listed, not announced.
                    if !self.firstPass {
                        self.model.show(Banner(icon: "checklist", tint: .orange, text: item.title), for: 6)
                    }
                }
                self.firstPass = false
            }
        }
    }
}
