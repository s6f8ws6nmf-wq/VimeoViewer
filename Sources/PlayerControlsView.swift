import AppKit

/// Ovládanie prehrávača v lište pod videom (namiesto ovládania vloženého vo videu Vimea).
final class PlayerControlsView: NSView {
    var onPlayPause: (() -> Void)?
    var onSkip: ((Double) -> Void)?
    var onVolume: ((Double) -> Void)?
    var onRate: ((Double) -> Void)?
    var onTrack: ((String?, String?) -> Void)?
    var onQuality: ((String) -> Void)?
    var onPiP: (() -> Void)?
    var onFullscreen: (() -> Void)?

    private let playButton = NSButton()
    private let timeLabel = NSTextField(labelWithString: "0:00 / 0:00")
    private let volumeButton = NSButton()
    private let volumeSlider = NSSlider(value: 1, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let ratePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let ccPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let qualityPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var lastVolume: Double = 1
    private var muted = false
    private static let rates: [Double] = [0.5, 0.75, 1, 1.25, 1.5, 2]

    init(timeline: CommentTimelineView) {
        super.init(frame: .zero)

        func icon(_ symbol: String, _ tip: String, _ action: Selector) -> NSButton {
            let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip) ?? NSImage(),
                             target: self, action: action)
            b.isBordered = false
            b.toolTip = tip
            b.setContentHuggingPriority(.required, for: .horizontal)
            b.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            return b
        }

        playButton.isBordered = false
        playButton.target = self
        playButton.action = #selector(playPause)
        playButton.toolTip = "Prehrať / Pozastaviť (⌘↩)"
        playButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 18, weight: .semibold)
        playButton.setContentHuggingPriority(.required, for: .horizontal)
        setPaused(true)

        let back = icon("gobackward.10", "Dozadu o 10 s", #selector(back10))
        let fwd = icon("goforward.10", "Dopredu o 10 s", #selector(fwd10))

        timeLabel.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        timeLabel.textColor = .secondaryLabelColor
        timeLabel.setContentHuggingPriority(.required, for: .horizontal)

        timeline.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        timeline.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)

        volumeButton.isBordered = false
        volumeButton.target = self
        volumeButton.action = #selector(toggleMute)
        volumeButton.toolTip = "Stlmiť / zapnúť zvuk"
        volumeButton.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 14, weight: .medium)
        volumeButton.setContentHuggingPriority(.required, for: .horizontal)
        volumeSlider.target = self
        volumeSlider.action = #selector(volumeChanged)
        volumeSlider.controlSize = .small
        volumeSlider.widthAnchor.constraint(equalToConstant: 80).isActive = true
        updateVolumeIcon()

        for p in [ratePopup, ccPopup, qualityPopup] {
            p.controlSize = .small
            p.font = .systemFont(ofSize: 11)
            p.target = self
            p.setContentHuggingPriority(.required, for: .horizontal)
        }
        ratePopup.addItems(withTitles: PlayerControlsView.rates.map { PlayerControlsView.rateTitle($0) })
        ratePopup.selectItem(at: 2)
        ratePopup.action = #selector(rateChanged)
        ratePopup.toolTip = "Rýchlosť prehrávania"
        ccPopup.addItem(withTitle: "CC vyp.")
        ccPopup.action = #selector(ccChanged)
        ccPopup.toolTip = "Titulky vo videu"
        ccPopup.isEnabled = false
        qualityPopup.addItem(withTitle: "Auto")
        qualityPopup.action = #selector(qualityChanged)
        qualityPopup.toolTip = "Kvalita videa"
        qualityPopup.isEnabled = false

        let pip = icon("pip.enter", "Obraz v obraze", #selector(pipTapped))
        let fs = icon("arrow.up.left.and.arrow.down.right", "Celá obrazovka", #selector(fsTapped))

        let row = NSStackView(views: [playButton, back, fwd, timeLabel, timeline, volumeButton, volumeSlider,
                                      ratePopup, ccPopup, qualityPopup, pip, fs])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 10
        row.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 12)
        row.setCustomSpacing(4, after: timeLabel)
        row.setCustomSpacing(4, after: timeline)
        row.setCustomSpacing(2, after: volumeButton)
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.topAnchor.constraint(equalTo: topAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor),
            heightAnchor.constraint(equalToConstant: 40),
            timeline.heightAnchor.constraint(equalToConstant: 28),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) not supported") }

    static func rateTitle(_ r: Double) -> String {
        let s = r == r.rounded() ? String(format: "%.0f", r) : String(format: "%g", r)
        return s.replacingOccurrences(of: ".", with: ",") + "×"
    }

    // MARK: Aktualizácia z prehrávača

    func update(time: Double, duration: Double) {
        timeLabel.stringValue = "\(VimeoLinks.formatTime(time)) / \(VimeoLinks.formatTime(duration))"
    }

    func update(paused: Bool, volume: Double, rate: Double, muted m: Bool) {
        setPaused(paused)
        muted = m || volume == 0
        if volume > 0 { lastVolume = volume }
        volumeSlider.doubleValue = muted ? 0 : volume
        updateVolumeIcon()
        if let i = PlayerControlsView.rates.firstIndex(where: { abs($0 - rate) < 0.01 }) { ratePopup.selectItem(at: i) }
    }

    /// tracks: (popis, jazyk, druh, aktívne), qualities: (popis, id, aktívna)
    func setOptions(tracks: [(String, String, String, Bool)], qualities: [(String, String, Bool)]) {
        ccPopup.removeAllItems()
        ccPopup.addItem(withTitle: "CC vyp.")
        ccPopup.lastItem?.representedObject = nil
        var sel = 0
        for (i, t) in tracks.enumerated() {
            ccPopup.addItem(withTitle: t.0)
            ccPopup.lastItem?.representedObject = [t.1, t.2]
            if t.3 { sel = i + 1 }
        }
        ccPopup.selectItem(at: sel)
        ccPopup.isEnabled = !tracks.isEmpty

        qualityPopup.removeAllItems()
        var qsel = 0
        for (i, q) in qualities.enumerated() {
            qualityPopup.addItem(withTitle: q.1 == "auto" ? "Auto" : q.0)
            qualityPopup.lastItem?.representedObject = q.1
            if q.2 { qsel = i }
        }
        if qualities.isEmpty { qualityPopup.addItem(withTitle: "Auto") }
        qualityPopup.selectItem(at: qsel)
        qualityPopup.isEnabled = qualities.count > 1
    }

    private func setPaused(_ p: Bool) {
        playButton.image = NSImage(systemSymbolName: p ? "play.fill" : "pause.fill", accessibilityDescription: p ? "Prehrať" : "Pozastaviť")
    }

    private func updateVolumeIcon() {
        let v = volumeSlider.doubleValue
        let name = (muted || v == 0) ? "speaker.slash.fill" : (v < 0.34 ? "speaker.wave.1.fill" : (v < 0.67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"))
        volumeButton.image = NSImage(systemSymbolName: name, accessibilityDescription: "Hlasitosť")
    }

    // MARK: Akcie

    @objc private func playPause() { onPlayPause?() }
    @objc private func back10() { onSkip?(-10) }
    @objc private func fwd10() { onSkip?(10) }
    @objc private func pipTapped() { onPiP?() }
    @objc private func fsTapped() { onFullscreen?() }

    @objc private func volumeChanged() {
        let v = volumeSlider.doubleValue
        muted = v == 0
        if v > 0 { lastVolume = v }
        updateVolumeIcon()
        onVolume?(v)
    }

    @objc private func toggleMute() {
        if muted || volumeSlider.doubleValue == 0 {
            volumeSlider.doubleValue = lastVolume > 0 ? lastVolume : 1
            muted = false
        } else {
            volumeSlider.doubleValue = 0
            muted = true
        }
        updateVolumeIcon()
        onVolume?(volumeSlider.doubleValue)
    }

    @objc private func rateChanged() {
        let i = ratePopup.indexOfSelectedItem
        guard i >= 0, i < PlayerControlsView.rates.count else { return }
        onRate?(PlayerControlsView.rates[i])
    }

    @objc private func ccChanged() {
        if let a = ccPopup.selectedItem?.representedObject as? [String], a.count == 2 { onTrack?(a[0], a[1]) }
        else { onTrack?(nil, nil) }
    }

    @objc private func qualityChanged() {
        if let q = qualityPopup.selectedItem?.representedObject as? String { onQuality?(q) }
    }
}
