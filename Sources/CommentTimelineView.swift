import AppKit

/// Tenká časová os pod videom: priebeh prehrávania + značky na miestach, kde sú komentáre.
/// Prechod myšou ukáže komentár, klik pretočí video.
final class CommentTimelineView: NSView, NSViewToolTipOwner {
    struct Marker {
        let time: Double
        let text: String
        let collaborator: Bool
    }

    var onSeek: ((Double) -> Void)?
    var markers: [Marker] = [] { didSet { rebuildToolTips(); needsDisplay = true } }
    var duration: Double = 0 { didSet { if oldValue != duration { rebuildToolTips(); needsDisplay = true } } }
    var currentTime: Double = 0 {
        didSet { if abs(x(for: oldValue) - x(for: currentTime)) >= 0.5 { needsDisplay = true } }
    }

    // MARK: Plynulý pohyb ukazovateľa (Vimeo hlási čas len ~4× za sekundu)

    private var anchorTime: Double = 0
    private var anchorDate = Date()
    private var playing = false
    private var rate: Double = 1
    private var tick: Timer?

    /// Čas hlásený prehrávačom – ukazovateľ sa medzi hláseniami dopočítava.
    func sync(time: Double) {
        anchorTime = time
        anchorDate = Date()
        if !playing { currentTime = time }
    }

    func setPlaying(_ p: Bool, rate r: Double) {
        anchorTime = currentTime
        anchorDate = Date()
        playing = p
        rate = r > 0 ? r : 1
        if playing && tick == nil {
            let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.step() }
            RunLoop.main.add(t, forMode: .common)
            tick = t
        } else if !playing {
            tick?.invalidate()
            tick = nil
        }
    }

    private func step() {
        guard window != nil, !isHiddenOrHasHiddenAncestor else { return }
        let t = anchorTime + Date().timeIntervalSince(anchorDate) * rate
        currentTime = duration > 0 ? min(t, duration) : t
    }

    private let inset: CGFloat = 14
    private var hoverX: CGFloat?

    override var isFlipped: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: NSView.noIntrinsicMetric, height: 28) }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateTrackingAreas()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        rebuildToolTips()
    }

    private var trackRect: NSRect {
        NSRect(x: inset, y: bounds.midY - 2, width: max(0, bounds.width - inset * 2), height: 4)
    }

    private func x(for t: Double) -> CGFloat {
        guard duration > 0 else { return trackRect.minX }
        return trackRect.minX + CGFloat(min(max(t / duration, 0), 1)) * trackRect.width
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        bounds.fill()
        let track = trackRect
        NSColor.quaternaryLabelColor.setFill()
        NSBezierPath(roundedRect: track, xRadius: 2, yRadius: 2).fill()
        if duration > 0 {
            var played = track
            played.size.width = x(for: currentTime) - track.minX
            NSColor.secondaryLabelColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: played, xRadius: 2, yRadius: 2).fill()
        }
        let orange = NSColor(red: 1.0, green: 0.42, blue: 0.0, alpha: 1)
        for m in markers where duration > 0 {
            let cx = x(for: m.time)
            let r: CGFloat = 4.5
            let dot = NSBezierPath(ovalIn: NSRect(x: cx - r, y: bounds.midY - r, width: r * 2, height: r * 2))
            (m.collaborator ? orange : NSColor.controlAccentColor).setFill()
            dot.fill()
            NSColor.windowBackgroundColor.setStroke()
            dot.lineWidth = 1.5
            dot.stroke()
        }
        if duration > 0 {
            let px = x(for: currentTime)
            NSColor.labelColor.setFill()
            NSRect(x: px - 1, y: track.minY - 5, width: 2, height: track.height + 10).fill()
        }
        if let hx = hoverX, duration > 0 {
            NSColor.labelColor.withAlphaComponent(0.25).setFill()
            NSRect(x: hx - 0.5, y: track.minY - 4, width: 1, height: track.height + 8).fill()
        }
    }

    // MARK: Popisy (tooltip) pre značky

    private func rebuildToolTips() {
        removeAllToolTips()
        guard duration > 0 else { return }
        for (i, m) in markers.enumerated() {
            let cx = x(for: m.time)
            addToolTip(NSRect(x: cx - 6, y: 0, width: 12, height: bounds.height), owner: self, userData: UnsafeMutableRawPointer(bitPattern: i + 1))
        }
    }

    func view(_ view: NSView, stringForToolTip tag: NSView.ToolTipTag, point: NSPoint, userData data: UnsafeMutableRawPointer?) -> String {
        guard let d = data else { return "" }
        let i = Int(bitPattern: d) - 1
        guard i >= 0, i < markers.count else { return "" }
        let m = markers[i]
        // Viac komentárov na rovnakom mieste zobraz spolu.
        let near = markers.filter { abs(x(for: $0.time) - x(for: m.time)) < 6 }
        return near.map { "\(VimeoLinks.formatTime($0.time))  \($0.text)" }.joined(separator: "\n\n")
    }

    // MARK: Myš

    override func mouseMoved(with event: NSEvent) {
        hoverX = convert(event.locationInWindow, from: nil).x
        needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        hoverX = nil
        needsDisplay = true
    }

    override func mouseDown(with event: NSEvent) {
        guard duration > 0 else { return }
        let px = convert(event.locationInWindow, from: nil).x
        // Klik blízko značky → presne na čas komentára.
        if let m = markers.min(by: { abs(x(for: $0.time) - px) < abs(x(for: $1.time) - px) }), abs(x(for: m.time) - px) < 7 {
            onSeek?(m.time)
            sync(time: m.time)
            currentTime = m.time
            return
        }
        let ratio = Double((px - trackRect.minX) / max(trackRect.width, 1))
        let target = min(max(ratio, 0), 1) * duration
        onSeek?(target)
        sync(time: target)
        currentTime = target
    }
}
