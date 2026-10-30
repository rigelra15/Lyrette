import SwiftUI
import AppKit
import Combine

@main
struct LyretteApp: App {
    @StateObject private var ticker: LyricTicker
    @StateObject private var statusItem: LyretteStatusItem

    init() {
        LegacyMigration.runIfNeeded()
        let ticker = LyricTicker()
        _ticker = StateObject(wrappedValue: ticker)
        _statusItem = StateObject(wrappedValue: LyretteStatusItem(ticker: ticker))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            ticker.checkSpotifyAutomationAccess()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            ticker.startMonitoringNowPlaying()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) {
            UpdateChecker.shared.checkOnLaunch()
        }
    }

    var body: some Scene {
        #if os(macOS)
        Settings {
            EmptyView()
        }
        #endif
    }
}

@MainActor
private final class RoundedArtworkView: NSImageView {
    override func draw(_ dirtyRect: NSRect) {
        let clipPath = NSBezierPath(
            roundedRect: bounds,
            xRadius: 4,
            yRadius: 4
        )
        clipPath.addClip()
        super.draw(dirtyRect)
    }
}

@MainActor
private final class LyretteStatusItemView: NSView {
    static let font = NSFont.systemFont(ofSize: 13, weight: .medium)
    static let artworkInset: CGFloat = 4
    static let artworkSize: CGFloat = 18
    static let textGap: CGFloat = 8
    static let trailingInset: CGFloat = 6
    /// Leading edge of the text area.
    static var textOrigin: CGFloat { artworkInset + artworkSize + textGap }

    private let clipView = NSView()
    private let titleField = NSTextField(labelWithString: "")
    private let artworkView = RoundedArtworkView()
    private let fadeMask = CAGradientLayer()
    private static let fadeWidth: CGFloat = 10
    /// NSTextField insets its text by about 2pt per side; without allowing for it the last glyph is clipped.
    static let cellPadding: CGFloat = 4
    private var marqueeNeedsRestart = true
    /// Overflow the running marquee was built for. If the real layout drifts from it (the status
    /// item resizes in steps), the marquee is rebuilt instead of scrolling by a stale distance.
    private var appliedOverflow: CGFloat = -1
    var action: (() -> Void)?

    var preferredWidth: CGFloat = 280 {
        didSet { invalidateIntrinsicContentSize() }
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: preferredWidth, height: 22)
    }

    static func textWidth(_ title: String) -> CGFloat {
        ceil((title as NSString).size(withAttributes: [.font: font]).width)
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        // The title is never truncated. When it is wider than the item it scrolls once
        // across the clip area (see restartMarquee) instead.
        titleField.font = Self.font
        titleField.lineBreakMode = .byClipping
        titleField.maximumNumberOfLines = 1
        titleField.usesSingleLineMode = true
        titleField.wantsLayer = true

        clipView.wantsLayer = true
        clipView.layer?.masksToBounds = true
        clipView.addSubview(titleField)
        addSubview(clipView)

        artworkView.imageScaling = .scaleProportionallyUpOrDown
        artworkView.imageAlignment = .alignCenter
        artworkView.wantsLayer = true
        artworkView.layer?.cornerRadius = 4
        artworkView.layer?.masksToBounds = true
        addSubview(artworkView)

        toolTip = "Lyrette"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(title: String, artwork: NSImage) {
        if titleField.stringValue != title {
            titleField.stringValue = title
            marqueeNeedsRestart = true
        }
        artworkView.image = artwork
        layoutContent()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = newSize.width != frame.width
        super.setFrameSize(newSize)
        if widthChanged { marqueeNeedsRestart = true }
        layoutContent()
    }

    override func layout() {
        super.layout()
        layoutContent()
    }

    private func layoutContent() {
        let height = bounds.height
        artworkView.frame = NSRect(
            x: Self.artworkInset,
            y: (height - Self.artworkSize) / 2,
            width: Self.artworkSize,
            height: Self.artworkSize
        )

        let available = max(0, bounds.width - Self.textOrigin - Self.trailingInset)
        clipView.frame = NSRect(x: Self.textOrigin, y: 0, width: available, height: height)
        fadeMask.frame = clipView.bounds

        let textWidth = Self.textWidth(titleField.stringValue) + Self.cellPadding
        let textHeight = ceil(Self.font.boundingRectForFont.height)
        titleField.frame = NSRect(
            x: 0,
            y: (height - textHeight) / 2,
            width: max(textWidth, available),
            height: textHeight
        )

        let overflow = max(0, textWidth - available)
        if marqueeNeedsRestart || abs(overflow - appliedOverflow) > 0.5 {
            marqueeNeedsRestart = false
            appliedOverflow = overflow
            restartMarquee(overflow: overflow)
        }
    }

    /// Hold on the start of the line, scroll to its end once, then stay there.
    private func restartMarquee(overflow: CGFloat) {
        guard let layer = titleField.layer else { return }
        layer.removeAnimation(forKey: "marquee")
        fadeMask.removeAnimation(forKey: "fade")
        guard overflow > 1 else {
            clipView.layer?.mask = nil
            return
        }
        configureFadeMask()
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

        let hold = 0.9
        let scroll = max(1.2, Double(overflow) / 45)
        let animation = CAKeyframeAnimation(keyPath: "transform.translation.x")
        animation.values = [0, 0, -overflow]
        animation.keyTimes = [0, NSNumber(value: hold / (hold + scroll)), 1]
        animation.timingFunctions = [
            CAMediaTimingFunction(name: .linear),
            CAMediaTimingFunction(name: .easeInEaseOut)
        ]
        animation.duration = hold + scroll
        animation.fillMode = .forwards
        animation.isRemovedOnCompletion = false
        layer.add(animation, forKey: "marquee")

        // The leading fade only appears once the text starts moving, and the trailing fade
        // clears when the end of the line is reached.
        let fade = CAKeyframeAnimation(keyPath: "colors")
        fade.values = [Self.fadeColors(left: 1, right: 0), Self.fadeColors(left: 1, right: 0), Self.fadeColors(left: 0, right: 1)]
        fade.keyTimes = animation.keyTimes
        fade.timingFunctions = animation.timingFunctions
        fade.duration = animation.duration
        fade.fillMode = .forwards
        fade.isRemovedOnCompletion = false
        fadeMask.add(fade, forKey: "fade")
    }

    /// Soft edges for text that is wider than the item, instead of a hard cut mid-letter.
    private func configureFadeMask() {
        let fraction = Self.fadeWidth / max(clipView.bounds.width, 1)
        fadeMask.startPoint = CGPoint(x: 0, y: 0.5)
        fadeMask.endPoint = CGPoint(x: 1, y: 0.5)
        fadeMask.locations = [0, NSNumber(value: fraction), NSNumber(value: 1 - fraction), 1]
        fadeMask.colors = Self.fadeColors(left: 1, right: 0)
        fadeMask.frame = clipView.bounds
        clipView.layer?.mask = fadeMask
    }

    /// `left`/`right` are the alpha of the outer edge stops: 1 = no fade, 0 = fully faded.
    private static func fadeColors(left: CGFloat, right: CGFloat) -> [CGColor] {
        [
            NSColor.black.withAlphaComponent(left).cgColor,
            NSColor.black.cgColor,
            NSColor.black.cgColor,
            NSColor.black.withAlphaComponent(right).cgColor
        ]
    }

    override func mouseDown(with event: NSEvent) {
        action?()
    }
}

@MainActor
final class LyretteStatusItem: NSObject, ObservableObject, NSPopoverDelegate {
    private let ticker: LyricTicker
    private let statusItem: NSStatusItem
    private let statusView = LyretteStatusItemView()
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var lastTitle = ""
    private var lastArtwork: Data?

    init(ticker: LyricTicker) {
        self.ticker = ticker
        statusItem = NSStatusBar.system.statusItem(withLength: 280)
        super.init()

        statusView.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        // Follow the status item's real size instead of setting the frame by hand: the menu bar
        // applies length changes on its own schedule, and a hand-set frame could drift from it.
        statusView.autoresizingMask = [.width, .height]
        statusItem.view = statusView
        statusView.action = { [weak self] in
            self?.togglePopover()
        }
        configurePopover()
        popover.delegate = self

        observation = ticker.objectWillChange.sink { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateStatusItem()
            }
        }
        updateStatusItem()
    }

    private func configurePopover() {
        let hosting = NSHostingController(
            rootView: LyretteMenuView(ticker: ticker)
        )
        // Without this the hosting controller resizes the popover whenever content changes,
        // which shifts it away from the status item.
        hosting.sizingOptions = []
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.contentSize = Self.popoverSize
    }

    private static let popoverSize = NSSize(
        width: LyrettePopoverMetrics.size.width,
        height: LyrettePopoverMetrics.size.height
    )

    private func updateStatusItem() {
        // The ticker publishes several times a second; only touch AppKit when something visible changed.
        let title = ticker.menuBarTitle
        let artworkData = ticker.albumArtData
        guard title != lastTitle || artworkData != lastArtwork else { return }
        lastTitle = title
        lastArtwork = artworkData
        statusView.update(title: title, artwork: makeAlbumArtwork())
        applyStatusWidth()
    }

    private static let minStatusWidth: CGFloat = 80
    private static let maxStatusWidth: CGFloat = 320

    /// Fits the item to its text (longer lines scroll). Skipped while the popover is open: the
    /// popover is anchored to this item, so resizing it would make the popover jump. It catches
    /// up when the popover closes.
    private func applyStatusWidth() {
        guard !popover.isShown else { return }
        let raw = LyretteStatusItemView.textOrigin
            + LyretteStatusItemView.textWidth(lastTitle) + LyretteStatusItemView.cellPadding
            + LyretteStatusItemView.trailingInset
        // Rounded up so small changes don't nudge the whole menu bar on every lyric line.
        let width = min(max(ceil(raw / 16) * 16, Self.minStatusWidth), Self.maxStatusWidth)
        setStatusWidth(width)
    }

    private func setStatusWidth(_ width: CGFloat) {
        guard width != statusItem.length else { return }
        statusView.preferredWidth = width
        statusItem.length = width
    }

    func popoverDidClose(_ notification: Notification) {
        applyStatusWidth()
    }

    private func makeAlbumArtwork() -> NSImage {
        if let image = ticker.albumArtImage?.copy() as? NSImage {
            image.size = NSSize(width: 18, height: 18)
            return image
        }

        let placeholder = NSImage(
            systemSymbolName: "music.note",
            accessibilityDescription: "Album artwork"
        ) ?? NSImage()
        placeholder.size = NSSize(width: 18, height: 18)
        placeholder.isTemplate = true
        return placeholder
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.contentSize = Self.popoverSize
            popover.show(
                relativeTo: statusView.bounds,
                of: statusView,
                preferredEdge: .minY
            )
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}

// MARK: - Window Manager
final class LyretteWindows: NSObject, NSWindowDelegate {
    static let shared = LyretteWindows()

    private var aboutWindow: NSWindow?

    func showAbout() {
        if let win = aboutWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let aboutVC = AboutViewController()
        let win = NSWindow(contentViewController: aboutVC)
        win.title = "About Lyrette"
        win.styleMask = [.titled, .closable]
        win.delegate = self
        win.isReleasedWhenClosed = false
        win.setContentSize(NSSize(width: 260, height: 250))
        aboutWindow = win
        win.center()
        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow == aboutWindow {
            aboutWindow = nil
        }
    }
}

// MARK: - About View Controller
final class AboutViewController: NSViewController {
    override func loadView() {
        let contentView = NSView(frame: NSRect(x: 0, y: 0, width: 260, height: 240))

        let icon = NSImageView(image: NSImage(named: "AppLogo") ?? NSApp.applicationIconImage)
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.wantsLayer = true
        icon.layer?.cornerRadius = 16
        icon.layer?.masksToBounds = true
        icon.frame = NSRect(x: 90, y: 152, width: 80, height: 80)
        contentView.addSubview(icon)

        let title = NSTextField(labelWithString: "Lyrette")
        title.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        title.alignment = .center
        title.frame = NSRect(x: 0, y: 118, width: 260, height: 24)
        contentView.addSubview(title)

        let appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
        let version = NSTextField(labelWithString: "Version \(appVersion)")
        version.font = NSFont.systemFont(ofSize: 12)
        version.textColor = .secondaryLabelColor
        version.alignment = .center
        version.frame = NSRect(x: 0, y: 102, width: 260, height: 16)
        contentView.addSubview(version)

        let desc = NSTextField(labelWithString: "Synced lyrics in your menu bar.\nWorks with Apple Music & Spotify.")
        desc.font = NSFont.systemFont(ofSize: 12)
        desc.alignment = .center
        desc.frame = NSRect(x: 20, y: 44, width: 220, height: 50)
        contentView.addSubview(desc)

        view = contentView
    }
}
