import SwiftUI

/// The notch outline: small outward flares at the top, rounded corners at the bottom.
struct NotchShape: Shape {
    static let flare: CGFloat = 6
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in r: CGRect) -> Path {
        let f = Self.flare
        let b = min(bottomRadius, r.height / 2)
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.minY))
        p.addQuadCurve(to: CGPoint(x: r.minX + f, y: r.minY + f), control: CGPoint(x: r.minX + f, y: r.minY))
        p.addLine(to: CGPoint(x: r.minX + f, y: r.maxY - b))
        p.addQuadCurve(to: CGPoint(x: r.minX + f + b, y: r.maxY), control: CGPoint(x: r.minX + f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - f - b, y: r.maxY))
        p.addQuadCurve(to: CGPoint(x: r.maxX - f, y: r.maxY - b), control: CGPoint(x: r.maxX - f, y: r.maxY))
        p.addLine(to: CGPoint(x: r.maxX - f, y: r.minY + f))
        p.addQuadCurve(to: CGPoint(x: r.maxX, y: r.minY), control: CGPoint(x: r.maxX - f, y: r.minY))
        p.closeSubpath()
        return p
    }
}

struct IslandView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        let size = model.size
        let shape = NotchShape(bottomRadius: model.expanded ? 24 : 10)

        ZStack(alignment: .top) {
            shape.fill(.black)
            if model.expanded {
                ExpandedView(model: model)
                    .padding(.horizontal, NotchShape.flare)
                    .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .top)))
            } else if model.showsCompact {
                CompactView(model: model)
                    .padding(.horizontal, NotchShape.flare)
                    .transition(.opacity)
            }
        }
        .frame(width: size.width + NotchShape.flare * 2, height: size.height)
        .clipShape(shape)
        .shadow(color: .black.opacity(model.expanded ? 0.45 : 0), radius: 14, y: 6)
        .animation(.spring(response: 0.36, dampingFraction: 0.78), value: size)
        .animation(.easeInOut(duration: 0.2), value: model.banner)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Compact (wings on both sides of the notch)

struct CompactView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        HStack(spacing: 0) {
            left.frame(width: model.wing, height: model.notch.height)
            Spacer(minLength: model.notch.width)
            right.frame(width: model.wing, height: model.notch.height)
        }
        .foregroundStyle(.white)
    }

    /// The top activity owns the right wing; the next one lends its icon to the left.
    @ViewBuilder private var left: some View {
        let slots = model.slots
        if let banner = model.banner {
            if let image = banner.image {
                Image(nsImage: image).resizable().frame(width: 20, height: 20)
            } else {
                Image(systemName: banner.icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(banner.tint)
            }
        } else if slots.count >= 2 {
            leading(slots[1])
        } else if let only = slots.first {
            leading(only)
        } else if model.cameraOn {
            symbol("video.fill", .green)
        } else {
            symbol("mic.fill", .orange)
        }
    }

    @ViewBuilder private var right: some View {
        if let banner = model.banner {
            if let level = banner.level {
                LevelBar(level: level, tint: banner.tint).frame(width: 48, height: 5)
            } else {
                Text(banner.text)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(banner.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        } else {
            HStack(spacing: 5) {
                if let first = model.slots.first { trailing(first) }
                if model.micApp != nil { Circle().fill(.orange).frame(width: 7, height: 7) }
                if model.cameraOn { Circle().fill(.green).frame(width: 7, height: 7) }
            }
        }
    }

    private func symbol(_ name: String, _ tint: Color) -> some View {
        Image(systemName: name)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(tint)
    }

    @ViewBuilder private func leading(_ slot: Slot) -> some View {
        switch slot {
        case .custom(let activity):
            symbol(activity.icon, activity.tint)
        case .call:
            symbol("phone.fill", .green)
        case .clock:
            symbol(model.stopwatchStart != nil ? "stopwatch" : "timer", .orange)
        case .event:
            symbol("calendar", .red)
        case .music:
            ArtworkView(model: model, side: model.notch.height - 12)
                .overlay {
                    if !model.isPlaying {
                        ZStack {
                            RoundedRectangle(cornerRadius: (model.notch.height - 12) * 0.22, style: .continuous)
                                .fill(.black.opacity(0.55))
                            Image(systemName: "pause.fill").font(.system(size: 11, weight: .bold))
                        }
                    }
                }
        }
    }

    @ViewBuilder private func trailing(_ slot: Slot) -> some View {
        switch slot {
        case .custom(let activity):
            if let progress = activity.progress {
                HStack(spacing: 4) {
                    ProgressRing(progress: progress, tint: activity.tint).frame(width: 15, height: 15)
                    Text("\(Int((progress * 100).rounded()))")
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(activity.tint)
                }
            } else {
                Text(activity.started, style: .timer)
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(activity.tint)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
        case .call(let call):
            Text(call.start, style: .timer)
                .font(.system(size: 13, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.green)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .clock:
            ClockText(model: model)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.orange)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        case .event(let event):
            Group {
                if event.start > Date() {
                    Countdown(end: event.start)
                } else {
                    Text("Şimdi")
                }
            }
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.red)
            .lineLimit(1)
            .minimumScaleFactor(0.7)
        case .music:
            if model.isPlaying {
                EqualizerBars(active: true)
                    .frame(width: 16, height: 14)
            } else {
                Image(systemName: "pause.fill")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.75))
            }
        }
    }
}

// MARK: - Expanded (opens on hover)

struct ExpandedView: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        VStack(spacing: 10) {
            Color.clear.frame(height: model.notch.height - 4)
            ForEach(model.activities.prefix(IslandModel.maxActivityRows)) { activity in
                ActivityRow(model: model, activity: activity)
            }
            musicRow
            if model.showsClockRow {
                Divider().overlay(Color.white.opacity(0.12))
                clockRow
            }
            if let stats = model.stats {
                Divider().overlay(Color.white.opacity(0.12))
                StatsRow(stats: stats)
            }
            if let call = model.call { callRow(call) }
            if let event = model.nextEvent { eventRow(event, symbol: "calendar", tint: .red) }
            if let reminder = model.nextReminder { eventRow(reminder, symbol: "checklist", tint: .orange) }
            if !model.unread.isEmpty { unreadRow }
            if model.hasIndicators { privacyRow }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .foregroundStyle(.white)
    }

    // MARK: Music

    @ViewBuilder private var musicRow: some View {
        if let track = model.track {
            VStack(spacing: 8) {
                HStack(spacing: 12) {
                    ArtworkView(model: model, side: 52)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(track.title.isEmpty ? "Bilinmeyen parça" : track.title)
                            .font(.system(size: 14, weight: .semibold))
                            .lineLimit(1)
                        Text(track.artist)
                            .font(.system(size: 12))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    if track.canControl {
                        HStack(spacing: 4) {
                            IconButton(symbol: "backward.fill") { model.onMusicCommand?("previous track") }
                            IconButton(symbol: track.isPlaying ? "pause.fill" : "play.fill", size: 20) {
                                model.onMusicCommand?("playpause")
                            }
                            IconButton(symbol: "forward.fill") { model.onMusicCommand?("next track") }
                        }
                    }
                }
                .frame(height: 52)
                if model.showsProgress, let position = model.position {
                    PlaybackBar(position: position, playing: track.isPlaying).frame(height: 12)
                }
            }
        } else {
            HStack(spacing: 10) {
                Image(systemName: "music.note")
                    .foregroundStyle(.white.opacity(0.5))
                Text("Şu an çalan bir şey yok")
                    .font(.system(size: 13))
                    .foregroundStyle(.white.opacity(0.6))
                Spacer()
            }
            .frame(height: 52)
        }
    }

    // MARK: Timer and stopwatch

    @ViewBuilder private var clockRow: some View {
        HStack(spacing: 8) {
            if model.timerEnd != nil || model.stopwatchStart != nil {
                Image(systemName: model.stopwatchStart != nil ? "stopwatch" : "timer").foregroundStyle(.orange)
                ClockText(model: model)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.orange)
                Spacer()
                if model.stopwatchStart != nil {
                    Button("Durdur") { model.stopStopwatch() }.buttonStyle(PillButtonStyle())
                } else {
                    Button("İptal") { model.cancelTimer() }.buttonStyle(PillButtonStyle())
                }
            } else {
                Image(systemName: "timer").foregroundStyle(.orange)
                let minutes = IslandModel.timerChoices[model.timerChoice]
                Button("−") { model.timerChoice = max(model.timerChoice - 1, 0) }
                    .buttonStyle(PillButtonStyle())
                Text("\(minutes) dk")
                    .font(.system(size: 13, weight: .semibold))
                    .monospacedDigit()
                    .frame(width: 52)
                Button("+") { model.timerChoice = min(model.timerChoice + 1, IslandModel.timerChoices.count - 1) }
                    .buttonStyle(PillButtonStyle())
                Button("Başlat") { model.startTimer(minutes: minutes) }
                    .buttonStyle(PillButtonStyle())
                Spacer()
                Button {
                    model.startStopwatch()
                } label: {
                    Label("Kronometre", systemImage: "stopwatch")
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .frame(height: 28)
    }

    // MARK: Calendar and privacy

    private func callRow(_ call: OngoingCall) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "phone.fill").foregroundStyle(.green)
            Text("Görüşme · \(call.app)")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            Text(call.start, style: .timer)
                .font(.system(size: 12, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(.green)
        }
        .frame(height: 20)
    }

    /// App icons with their unread counts, read from the Dock.
    private var unreadRow: some View {
        HStack(spacing: 12) {
            ForEach(model.unread) { badge in
                HStack(spacing: 5) {
                    Image(nsImage: badge.icon).resizable().frame(width: 20, height: 20)
                    Text(badge.count)
                        .font(.system(size: 12, weight: .semibold))
                        .monospacedDigit()
                }
                .help(badge.name)
            }
            Spacer()
        }
        .frame(height: 24)
    }

    private func eventRow(_ event: UpcomingEvent, symbol: String, tint: Color) -> some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(tint)
            Text(event.title)
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            Spacer()
            Text(event.start, style: .time)
                .font(.system(size: 12))
                .foregroundStyle(.white.opacity(0.6))
        }
        .frame(height: 20)
    }

    private var privacyRow: some View {
        HStack(spacing: 12) {
            if let app = model.micApp {
                HStack(spacing: 5) {
                    Circle().fill(.orange).frame(width: 7, height: 7)
                    Text("Mikrofon: \(app)")
                }
            }
            if model.cameraOn {
                HStack(spacing: 5) {
                    Circle().fill(.green).frame(width: 7, height: 7)
                    Text("Kamera açık")
                }
            }
            Spacer()
        }
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.7))
        .lineLimit(1)
        .frame(height: 18)
    }
}

/// System figures: CPU, GPU, memory, disk and network.
struct StatsRow: View {
    var stats: SystemStats

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            tile("CPU", percent(stats.cpu), level: stats.cpu)
            if let gpu = stats.gpu { tile("GPU", percent(gpu), level: gpu) }
            let memory = stats.memoryTotal > 0 ? Double(stats.memoryUsed) / Double(stats.memoryTotal) : 0
            tile("BELLEK", gigabytes(Double(stats.memoryUsed)), level: memory)
            if let free = stats.diskFree, let total = stats.diskTotal, total > 0 {
                tile("DİSK BOŞ", gigabytes(Double(free)), level: 1 - Double(free) / Double(total))
            }
            if let temperature = stats.temperature {
                // 30 °C reads as empty and 100 °C as full, so the bar turns yellow near 72 °C and red near 90 °C.
                tile("ISI", "\(Int(temperature.rounded()))°", level: (temperature - 30) / 70)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text("AĞ").font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.5))
                Text("↓ " + rate(stats.down))
                Text("↑ " + rate(stats.up))
            }
            .font(.system(size: 10, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 40, alignment: .top)
    }

    private func tile(_ label: String, _ value: String, level: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 9, weight: .medium)).foregroundStyle(.white.opacity(0.5))
            Text(value).font(.system(size: 13, weight: .semibold)).monospacedDigit()
            LevelBar(level: level, tint: level < 0.6 ? .green : level < 0.85 ? .yellow : .red).frame(height: 3)
        }
        .lineLimit(1)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func percent(_ value: Double) -> String { "%\(Int((value * 100).rounded()))" }

    private func gigabytes(_ bytes: Double) -> String {
        let value = bytes / 1_073_741_824
        return value >= 100 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
    }

    private func rate(_ bytesPerSecond: Double) -> String {
        if bytesPerSecond >= 1_048_576 { return String(format: "%.1f MB/s", bytesPerSecond / 1_048_576) }
        return String(format: "%.0f KB/s", bytesPerSecond / 1024)
    }
}

/// One activity pushed with the `notch` command.
struct ActivityRow: View {
    @ObservedObject var model: IslandModel
    var activity: CustomActivity

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: activity.icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(activity.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(activity.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if !activity.detail.isEmpty {
                        Text(activity.detail)
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.6))
                            .lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    Group {
                        if let progress = activity.progress {
                            Text("%\(Int((progress * 100).rounded()))")
                        } else {
                            Text(activity.started, style: .timer)
                        }
                    }
                    .font(.system(size: 12, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(activity.tint)
                }
                if let progress = activity.progress {
                    LevelBar(level: progress, tint: activity.tint).frame(height: 4)
                }
            }
            IconButton(symbol: "xmark", size: 10, side: 22) { model.removeActivity(activity.id) }
        }
        .frame(height: 38)
    }
}

// MARK: - Pieces

struct ArtworkView: View {
    @ObservedObject var model: IslandModel
    var side: CGFloat

    var body: some View {
        Group {
            if let image = model.artwork {
                Image(nsImage: image).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [.pink, .purple], startPoint: .top, endPoint: .bottom)
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.5, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: side * 0.22, style: .continuous))
    }
}

struct Countdown: View {
    var end: Date

    var body: some View {
        Text(timerInterval: Date()...max(end, Date().addingTimeInterval(0.1)), countsDown: true)
            .monospacedDigit()
    }
}

/// Remaining time of the timer, or elapsed time of the stopwatch.
struct ClockText: View {
    @ObservedObject var model: IslandModel

    var body: some View {
        if let start = model.stopwatchStart {
            Text(start, style: .timer).monospacedDigit()
        } else if let end = model.timerEnd, end > Date() {
            Countdown(end: end)
        }
    }
}

struct LevelBar: View {
    var level: Double
    var tint: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.18))
                Capsule().fill(tint).frame(width: proxy.size.width * min(max(level, 0), 1))
            }
        }
        .animation(.easeOut(duration: 0.15), value: level)
    }
}

struct ProgressRing: View {
    var progress: Double
    var tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(Color.white.opacity(0.2), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .animation(.easeOut(duration: 0.3), value: progress)
    }
}

struct PlaybackBar: View {
    var position: PlaybackPosition
    var playing: Bool

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            let moved = playing ? context.date.timeIntervalSince(position.asOf) : 0
            let elapsed = min(max(position.elapsed + moved, 0), position.duration)
            HStack(spacing: 8) {
                Text(Self.format(elapsed))
                LevelBar(level: position.duration > 0 ? elapsed / position.duration : 0, tint: .white)
                    .frame(height: 4)
                Text(Self.format(position.duration))
            }
            .font(.system(size: 10))
            .monospacedDigit()
            .foregroundStyle(.white.opacity(0.6))
        }
    }

    private static func format(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct EqualizerBars: View {
    var active: Bool

    var body: some View {
        TimelineView(.animation(minimumInterval: 0.1, paused: !active)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .center, spacing: 2) {
                ForEach(0..<4, id: \.self) { i in
                    let phase = t * (5.0 + Double(i) * 1.3) + Double(i) * 1.7
                    let level = active ? 0.35 + 0.65 * abs(sin(phase)) : 0.3
                    Capsule()
                        .fill(Color.white.opacity(0.9))
                        .frame(width: 2.5, height: 14 * level)
                }
            }
            .frame(maxHeight: .infinity)
        }
    }
}

struct IconButton: View {
    var symbol: String
    var size: CGFloat = 15
    var side: CGFloat = 34
    var action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: size, weight: .semibold))
                .frame(width: side, height: side)
                .background(Circle().fill(Color.white.opacity(hovering ? 0.16 : 0)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

struct PillButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12, weight: .medium))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Capsule().fill(Color.white.opacity(configuration.isPressed ? 0.3 : 0.14)))
            .contentShape(Capsule())
    }
}
