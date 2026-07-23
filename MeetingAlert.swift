import AppKit
import EventKit
import Foundation

// MARK: - Models

struct Meeting {
    let id: String            // eventIdentifier + occurrence start
    let title: String
    let startDate: Date
    let endDate: Date
    let joinURL: URL?
}

// MARK: - App Delegate

class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    var statusItem: NSStatusItem!
    let store = EKEventStore()
    var pollTimer: Timer?
    var alertTimer: Timer?
    var countdownTimer: Timer?
    var overlayWindows: [NSWindow] = []
    var alertedIDs: Set<String> = []
    var snoozedUntil: [String: Date] = [:]
    var nextMeeting: Meeting?
    var hasCalendarAccess = false
    var testHasURL = true
    var syncTimer: Timer?
    var lastUpcoming: [Meeting] = []
    var lastGoogleSyncAt: Date? = nil
    // [meetingID: [leadMinutes: Timer]] — 各アラートを精密タイマーで個別管理
    var scheduledAlertTimers: [String: [Int: Timer]] = [:]

    var leadTimeMinutesList: Set<Int> {
        get {
            let saved = UserDefaults.standard.array(forKey: "leadTimeMinutesList") as? [Int] ?? []
            return saved.isEmpty ? [1] : Set(saved)
        }
        set { UserDefaults.standard.set(Array(newValue), forKey: "leadTimeMinutesList") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusTitle()
        requestAccess()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in self?.poll() }

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(calendarStoreChanged),
            name: .EKEventStoreChanged,
            object: store)
    }

    @objc func calendarStoreChanged() {
        DispatchQueue.main.async {
            self.lastGoogleSyncAt = Date()
            self.poll()
        }
    }

    // MARK: - Calendar Access

    func requestAccess() {
        let handler: (Bool, Error?) -> Void = { [weak self] granted, _ in
            DispatchQueue.main.async {
                self?.hasCalendarAccess = granted
                if granted { self?.poll() } else { self?.buildMenu() }
            }
        }
        if #available(macOS 14.0, *) {
            store.requestFullAccessToEvents(completion: handler)
        } else {
            store.requestAccess(to: .event, completion: handler)
        }
    }

    // MARK: - Polling

    func poll() {
        guard hasCalendarAccess else { return }
        let now = Date()
        let predicate = store.predicateForEvents(withStart: now, end: now.addingTimeInterval(24 * 3600), calendars: nil)
        let events = store.events(matching: predicate)
            .filter { !$0.isAllDay }
            .filter { $0.status != .canceled }
            .filter { !isDeclined($0) }
            .sorted { $0.startDate < $1.startDate }

        let meetings = events.map { ev -> Meeting in
            let occurrence = "\(ev.eventIdentifier ?? UUID().uuidString)_\(ev.startDate.timeIntervalSince1970)"
            return Meeting(
                id: occurrence,
                title: ev.title ?? "無題の予定",
                startDate: ev.startDate,
                endDate: ev.endDate,
                joinURL: extractJoinURL(ev)
            )
        }

        nextMeeting = meetings.first { $0.startDate > now }
        lastUpcoming = Array(meetings.prefix(5))
        updateStatusTitle()
        buildMenu(upcoming: lastUpcoming)

        // Fire alerts — 精密タイマーでスケジュール
        scheduleAlerts(for: meetings)
        // Prune old IDs
        if alertedIDs.count > 200 { alertedIDs.removeAll() }
    }

    func scheduleAlerts(for meetings: [Meeting]) {
        let now = Date()
        let currentLeads = leadTimeMinutesList
        let activeMeetingIDs = Set(meetings.map { $0.id })

        // 消えた会議のタイマーをキャンセル
        for id in Array(scheduledAlertTimers.keys) where !activeMeetingIDs.contains(id) {
            scheduledAlertTimers[id]!.values.forEach { $0.invalidate() }
            scheduledAlertTimers.removeValue(forKey: id)
        }
        // 解除されたリードタイムのタイマーをキャンセル
        for id in Array(scheduledAlertTimers.keys) {
            for lead in Array(scheduledAlertTimers[id]!.keys) where !currentLeads.contains(lead) {
                scheduledAlertTimers[id]![lead]?.invalidate()
                scheduledAlertTimers[id]!.removeValue(forKey: lead)
            }
        }

        for m in meetings {
            if let snooze = snoozedUntil[m.id] {
                if now >= snooze && now < m.endDate {
                    snoozedUntil.removeValue(forKey: m.id)
                    showOverlay(for: m)
                }
                continue
            }
            for lead in currentLeads {
                let alertID = "\(m.id)_\(lead)"
                guard !alertedIDs.contains(alertID) else { continue }
                guard scheduledAlertTimers[m.id]?[lead] == nil else { continue }

                let alertAt = m.startDate.addingTimeInterval(-TimeInterval(lead * 60))
                if alertAt <= now {
                    // すでに過ぎていたら即発火(ウィンドウ内のみ)
                    if now < m.startDate.addingTimeInterval(60) {
                        alertedIDs.insert(alertID)
                        showOverlay(for: m)
                    }
                } else {
                    // 精密タイマーで alertAt ちょうどに発火
                    if scheduledAlertTimers[m.id] == nil { scheduledAlertTimers[m.id] = [:] }
                    scheduledAlertTimers[m.id]![lead] = Timer.scheduledTimer(
                        withTimeInterval: alertAt.timeIntervalSinceNow,
                        repeats: false
                    ) { [weak self] _ in
                        guard let self else { return }
                        self.scheduledAlertTimers[m.id]?.removeValue(forKey: lead)
                        guard !self.alertedIDs.contains(alertID), Date() < m.endDate else { return }
                        self.alertedIDs.insert(alertID)
                        self.showOverlay(for: m)
                    }
                }
            }
        }
    }

    func isDeclined(_ ev: EKEvent) -> Bool {
        guard let attendees = ev.attendees else { return false }
        for a in attendees where a.isCurrentUser {
            return a.participantStatus == .declined
        }
        return false
    }

    func extractJoinURL(_ ev: EKEvent) -> URL? {
        var candidates: [String] = []
        if let u = ev.url?.absoluteString { candidates.append(u) }
        if let loc = ev.location { candidates.append(loc) }
        if let notes = ev.notes { candidates.append(notes) }
        let pattern = #"https://(meet\.google\.com|[\w-]*\.?zoom\.us|teams\.microsoft\.com|teams\.live\.com)[^\s<>"')\]]*"#
        for text in candidates {
            if let range = text.range(of: pattern, options: .regularExpression) {
                return URL(string: String(text[range]))
            }
        }
        return nil
    }

    // MARK: - Status Item

    func makeClockIcon() -> NSImage {
        let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            let ctx = NSGraphicsContext.current!.cgContext
            let cx = rect.midX, cy = rect.midY
            let r: CGFloat = 7.2

            ctx.setStrokeColor(NSColor.black.cgColor)
            ctx.setFillColor(NSColor.black.cgColor)
            ctx.setLineCap(.round)

            // Outer circle
            ctx.setLineWidth(1.5)
            ctx.addEllipse(in: CGRect(x: cx - r, y: cy - r, width: r * 2, height: r * 2))
            ctx.strokePath()

            // Hour hand — 10 o'clock (upper-left)
            let ha: CGFloat = 5 * .pi / 6
            ctx.setLineWidth(1.6)
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: cx + cos(ha) * r * 0.52, y: cy + sin(ha) * r * 0.52))
            ctx.strokePath()

            // Minute hand — 12 o'clock (straight up)
            let ma: CGFloat = .pi / 2
            ctx.setLineWidth(1.3)
            ctx.move(to: CGPoint(x: cx, y: cy))
            ctx.addLine(to: CGPoint(x: cx + cos(ma) * r * 0.72, y: cy + sin(ma) * r * 0.72))
            ctx.strokePath()

            // Center dot
            ctx.addEllipse(in: CGRect(x: cx - 1.2, y: cy - 1.2, width: 2.4, height: 2.4))
            ctx.fillPath()

            return true
        }
        img.isTemplate = true
        return img
    }

    func updateStatusTitle() {
        guard let btn = statusItem.button else { return }
        btn.image = makeClockIcon()
        btn.imagePosition = nextMeeting != nil ? .imageLeft : .imageOnly
        if let m = nextMeeting {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            let title = m.title.count > 12 ? String(m.title.prefix(12)) + "…" : m.title
            btn.title = " \(f.string(from: m.startDate)) \(title)"
        } else {
            btn.title = ""
        }
    }

    // MARK: - Menu

    func buildMenu(upcoming: [Meeting] = []) {
        let menu = NSMenu()

        if !hasCalendarAccess {
            let item = NSMenuItem(title: "カレンダーへのアクセスが必要です", action: #selector(openPrivacySettings), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
            menu.addItem(.separator())
        }

        // Upcoming
        let header = NSMenuItem()
        header.attributedTitle = NSAttributedString(string: "今日の予定", attributes: [
            .font: NSFont.systemFont(ofSize: 10, weight: .semibold),
            .foregroundColor: NSColor(name: nil) {
                $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
                    ? NSColor(white: 0.82, alpha: 1) : NSColor(white: 0.2, alpha: 1)
            }
        ])
        header.isEnabled = false
        menu.addItem(header)

        if upcoming.isEmpty {
            let item = NSMenuItem(title: "  予定なし", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        } else {
            let f = DateFormatter()
            f.dateFormat = "HH:mm"
            for m in upcoming {
                let title = "  \(f.string(from: m.startDate))  \(m.title)"
                if let url = m.joinURL {
                    let item = NSMenuItem(title: title, action: #selector(openMeetingURL(_:)), keyEquivalent: "")
                    item.target = self
                    item.representedObject = url
                    item.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
                    menu.addItem(item)
                } else {
                    let item = NSMenuItem(title: title, action: #selector(noOp), keyEquivalent: "")
                    item.target = self
                    menu.addItem(item)
                }
            }
        }

        menu.addItem(.separator())

        // Lead time (複数選択可 — カスタムビューでメニューを閉じない)
        let leadMenu = NSMenu()
        let current = leadTimeMinutesList
        for minutes in [1, 3, 5, 10, 15, 30] {
            let item = NSMenuItem()
            let view = CheckboxMenuItemView(title: "\(minutes)分前", checked: current.contains(minutes))
            view.onToggle = { [weak self, weak view] in
                guard let self else { return }
                var list = self.leadTimeMinutesList
                if list.contains(minutes) {
                    list.remove(minutes)
                    if list.isEmpty { list.insert(minutes) }
                } else {
                    list.insert(minutes)
                }
                self.leadTimeMinutesList = list
                view?.setChecked(list.contains(minutes))
            }
            item.view = view
            leadMenu.addItem(item)
        }
        let leadItem = NSMenuItem(title: "通知タイミング", action: nil, keyEquivalent: "")
        menu.addItem(leadItem)
        menu.setSubmenu(leadMenu, for: leadItem)

        // Test
        let testMenu = NSMenu()
        let withURL = NSMenuItem(title: "URLあり", action: #selector(testWithURL), keyEquivalent: "")
        withURL.target = self
        testMenu.addItem(withURL)
        let withoutURL = NSMenuItem(title: "URLなし", action: #selector(testWithoutURL), keyEquivalent: "")
        withoutURL.target = self
        testMenu.addItem(withoutURL)
        let testItem = NSMenuItem(title: "テスト表示", action: nil, keyEquivalent: "")
        menu.addItem(testItem)
        menu.setSubmenu(testMenu, for: testItem)

        menu.addItem(.separator())

        // Launch at Login
        let loginItem = NSMenuItem(
            title: isLaunchAtLoginEnabled ? "✓ ログイン時に起動" : "  ログイン時に起動",
            action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        menu.addItem(loginItem)

        let syncText: String
        if let last = lastGoogleSyncAt {
            let f = DateFormatter()
            f.dateFormat = "HH:mm:ss"
            syncText = "最終同期: \(f.string(from: last))"
        } else {
            syncText = "最終同期: 未検出"
        }
        let syncItem = NSMenuItem(title: syncText, action: nil, keyEquivalent: "")
        syncItem.isEnabled = false
        menu.addItem(syncItem)

        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        statusItem.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        buildMenu(upcoming: lastUpcoming)
    }

    @objc func noOp() {}

    @objc func openMeetingURL(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL {
            NSWorkspace.shared.open(url)
        }
    }

    @objc func openPrivacySettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }

    @objc func testOverlay() {
        let m = Meeting(
            id: "test",
            title: "テスト会議",
            startDate: Date().addingTimeInterval(60),
            endDate: Date().addingTimeInterval(3660),
            joinURL: testHasURL ? URL(string: "https://meet.google.com/test") : nil
        )
        showOverlay(for: m)
    }

    @objc func testWithURL() {
        testHasURL = true
        testOverlay()
    }

    @objc func testWithoutURL() {
        testHasURL = false
        testOverlay()
    }

    // MARK: - Overlay

    func showOverlay(for meeting: Meeting) {
        closeOverlay()
        NSSound(named: "Glass")?.play()

        for screen in NSScreen.screens {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false)
            win.level = .screenSaver
            win.isOpaque = false
            win.backgroundColor = NSColor.black.withAlphaComponent(0.88)
            // 黒背景オーバーレイ上ではシステムのLight/Darkに関わらず常に明色でレンダリング
            win.appearance = NSAppearance(named: .darkAqua)
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            win.isReleasedWhenClosed = false
            win.contentView = makeOverlayView(for: meeting, frame: screen.frame)
            win.makeKeyAndOrderFront(nil)
            overlayWindows.append(win)
        }
        NSApp.activate(ignoringOtherApps: true)

        // Countdown updates
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.updateCountdowns(startDate: meeting.startDate)
        }
    }

    var countdownLabels: [NSTextField] = []

    func makeOverlayView(for meeting: Meeting, frame: NSRect) -> NSView {
        let view = NSView(frame: NSRect(origin: .zero, size: frame.size))

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 24
        stack.translatesAutoresizingMaskIntoConstraints = false

        let badge = label("まもなく", size: 24, weight: .medium, color: NSColor(white: 0.7, alpha: 1))
        let title = label(meeting.title, size: 56, weight: .bold, color: .white)
        title.maximumNumberOfLines = 2
        title.alignment = .center
        title.preferredMaxLayoutWidth = frame.width * 0.8

        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        let time = label("\(f.string(from: meeting.startDate)) 開始", size: 28, weight: .regular, color: NSColor(white: 0.8, alpha: 1))

        let countdown = label("", size: 40, weight: .semibold, color: NSColor(red: 1.0, green: 0.75, blue: 0.0, alpha: 1))
        countdownLabels.append(countdown)

        stack.addArrangedSubview(badge)
        stack.addArrangedSubview(title)
        stack.addArrangedSubview(time)
        stack.addArrangedSubview(countdown)

        // Buttons
        let buttons = NSStackView()
        buttons.orientation = .horizontal
        buttons.spacing = 20

        if let url = meeting.joinURL {
            let join = button("参加する", action: #selector(joinMeeting(_:)))
            join.keyEquivalent = "\r"
            join.image = NSImage(systemSymbolName: "video.fill", accessibilityDescription: nil)
            join.imagePosition = .imageLeading
            joinURL = url
            buttons.addArrangedSubview(join)
        }
        let snooze = button("5分後に再通知", action: #selector(snoozeMeeting))
        snoozeTarget = meeting
        let close = button("閉じる", action: #selector(dismissOverlay))
        close.keyEquivalent = "\u{1b}"
        buttons.addArrangedSubview(snooze)
        buttons.addArrangedSubview(close)

        stack.addArrangedSubview(buttons)
        stack.setCustomSpacing(48, after: countdown)

        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }

    var joinURL: URL?
    var snoozeTarget: Meeting?

    func label(_ text: String, size: CGFloat, weight: NSFont.Weight, color: NSColor) -> NSTextField {
        let l = NSTextField(labelWithString: text)
        l.font = NSFont.systemFont(ofSize: size, weight: weight)
        l.textColor = color
        return l
    }

    func button(_ title: String, action: Selector) -> NSButton {
        let b = HoverButton(title: title, target: self, action: action)
        b.bezelStyle = .rounded
        b.controlSize = .large
        b.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        return b
    }

    func updateCountdowns(startDate: Date) {
        let s = Int(startDate.timeIntervalSinceNow)
        let text: String
        if s > 0 {
            text = s >= 60 ? "開始まで \(s / 60)分\(s % 60)秒" : "開始まで \(s)秒"
        } else {
            text = "会議開始済み（\(-s / 60)分経過）"
        }
        for l in countdownLabels { l.stringValue = text }
    }

    @objc func joinMeeting(_ sender: NSButton) {
        if let url = joinURL { NSWorkspace.shared.open(url) }
        closeOverlay()
    }

    @objc func snoozeMeeting() {
        if let m = snoozeTarget {
            snoozedUntil[m.id] = Date().addingTimeInterval(5 * 60)
        }
        closeOverlay()
    }

    @objc func dismissOverlay() {
        closeOverlay()
    }

    func closeOverlay() {
        countdownTimer?.invalidate()
        countdownTimer = nil
        countdownLabels.removeAll()
        for w in overlayWindows { w.orderOut(nil) }
        overlayWindows.removeAll()
        joinURL = nil
        snoozeTarget = nil
    }

    // MARK: - Launch at Login

    var launchAgentPlistPath: String {
        "\(NSHomeDirectory())/Library/LaunchAgents/com.kota.meeting-alert.plist"
    }

    var isLaunchAtLoginEnabled: Bool {
        FileManager.default.fileExists(atPath: launchAgentPlistPath)
    }

    @objc func toggleLaunchAtLogin() {
        if isLaunchAtLoginEnabled {
            runLaunchctl(["unload", launchAgentPlistPath])
            try? FileManager.default.removeItem(atPath: launchAgentPlistPath)
        } else {
            let binary = Bundle.main.executablePath ?? (Bundle.main.bundlePath + "/Contents/MacOS/MeetingAlert")
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
              "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
              <key>Label</key><string>com.kota.meeting-alert</string>
              <key>ProgramArguments</key>
              <array>
                <string>\(binary)</string>
              </array>
              <key>RunAtLoad</key><true/>
              <key>KeepAlive</key><true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: launchAgentPlistPath, atomically: true, encoding: .utf8)
            runLaunchctl(["load", launchAgentPlistPath])
        }
        poll()
    }

    @discardableResult
    func runLaunchctl(_ args: [String]) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try? p.run(); p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

// MARK: - CheckboxMenuItemView

/// 通知タイミングの複数選択メニュー項目。mouseDown で super を呼ばないことで
/// NSMenu が閉じるのを防ぎ、連続してチェックを切り替えられるようにする。
final class CheckboxMenuItemView: NSView {
    private(set) var checked: Bool
    private let checkLabel: NSTextField
    private let titleLabel: NSTextField
    var onToggle: (() -> Void)?

    init(title: String, checked: Bool) {
        self.checked = checked
        checkLabel = NSTextField(labelWithString: "")
        titleLabel = NSTextField(labelWithString: title)
        super.init(frame: NSRect(x: 0, y: 0, width: 180, height: 20))
        wantsLayer = true

        for tf in [checkLabel, titleLabel] {
            tf.isBordered = false
            tf.isEditable = false
            tf.drawsBackground = false
            tf.font = NSFont.menuFont(ofSize: 0)
            tf.translatesAutoresizingMaskIntoConstraints = false
            addSubview(tf)
        }
        NSLayoutConstraint.activate([
            checkLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            checkLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            checkLabel.widthAnchor.constraint(equalToConstant: 18),
            titleLabel.leadingAnchor.constraint(equalTo: checkLabel.trailingAnchor, constant: 4),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        refreshUI(highlighted: false)
    }

    required init?(coder: NSCoder) { fatalError() }

    func setChecked(_ value: Bool) {
        checked = value
        checkLabel.stringValue = value ? "✓" : ""
    }

    private func refreshUI(highlighted: Bool) {
        checkLabel.stringValue = checked ? "✓" : ""
        if highlighted {
            layer?.backgroundColor = NSColor.selectedContentBackgroundColor.cgColor
            checkLabel.textColor = .selectedMenuItemTextColor
            titleLabel.textColor = .selectedMenuItemTextColor
        } else {
            layer?.backgroundColor = .clear
            checkLabel.textColor = .labelColor
            titleLabel.textColor = .labelColor
        }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for a in trackingAreas { removeTrackingArea(a) }
        addTrackingArea(NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) { refreshUI(highlighted: true) }
    override func mouseExited(with event: NSEvent) { refreshUI(highlighted: false) }

    override func mouseDown(with event: NSEvent) {
        checked.toggle()
        checkLabel.stringValue = checked ? "✓" : ""
        onToggle?()
        // super を呼ばない → NSMenu が mouseUp を検知せず閉じない
    }
}

// MARK: - HoverButton

/// オーバーレイのボタン用: マウスホバー時に軽い視覚フィードバック（透明度アニメーション + ポインタカーソル）を出す。
/// システム標準の NSButton だと Light/Dark 問わずホバー時の見た目が地味なので、フルスクリーン警告 UI としての手応えを補強する目的。
final class HoverButton: NSButton {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        wantsLayer = true
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self,
            userInfo: nil)
        addTrackingArea(area)
    }

    private var cursorPushed = false

    override func mouseEntered(with event: NSEvent) {
        if !cursorPushed {
            NSCursor.pointingHand.push()
            cursorPushed = true
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 0.7
        }
    }

    override func mouseExited(with event: NSEvent) {
        if cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.12
            ctx.allowsImplicitAnimation = true
            animator().alphaValue = 1.0
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        // window が消える／張り替わるタイミングで pop 忘れを防ぐ
        if newWindow == nil, cursorPushed {
            NSCursor.pop()
            cursorPushed = false
        }
    }
}

// MARK: - Entry Point

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
