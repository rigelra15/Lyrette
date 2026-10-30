import SwiftUI
import AppKit
import Combine

@main
struct LyricBarApp: App {
    @StateObject private var ticker: LyricTicker
    @StateObject private var statusItem: LyricBarStatusItem

    init() {
        let ticker = LyricTicker()
        _ticker = StateObject(wrappedValue: ticker)
        _statusItem = StateObject(wrappedValue: LyricBarStatusItem(ticker: ticker))

        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            ticker.checkSpotifyAutomationAccess()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
            ticker.startMonitoringNowPlaying()
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
private final class LyricBarStatusItemView: NSView {
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
    private var marqueeNeedsRestart = true
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

        toolTip = "LyricBar"
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

        let textWidth = Self.textWidth(titleField.stringValue)
        let textHeight = ceil(Self.font.boundingRectForFont.height)
        titleField.frame = NSRect(
            x: 0,
            y: (height - textHeight) / 2,
            width: max(textWidth, available),
            height: textHeight
        )

        if marqueeNeedsRestart {
            marqueeNeedsRestart = false
            restartMarquee(overflow: textWidth - available)
        }
    }

    /// Hold on the start of the line, scroll to its end once, then stay there.
    private func restartMarquee(overflow: CGFloat) {
        guard let layer = titleField.layer else { return }
        layer.removeAnimation(forKey: "marquee")
        guard overflow > 1, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }

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
    }

    override func mouseDown(with event: NSEvent) {
        action?()
    }
}

@MainActor
final class LyricBarStatusItem: NSObject, ObservableObject, NSPopoverDelegate {
    private let ticker: LyricTicker
    private let statusItem: NSStatusItem
    private let statusView = LyricBarStatusItemView()
    private let popover = NSPopover()
    private var observation: AnyCancellable?
    private var lastTitle = ""
    private var lastArtwork: Data?

    init(ticker: LyricTicker) {
        self.ticker = ticker
        statusItem = NSStatusBar.system.statusItem(withLength: 280)
        super.init()

        statusView.frame = NSRect(x: 0, y: 0, width: 280, height: 22)
        statusView.autoresizingMask = []
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
            rootView: LyricBarMenuView(ticker: ticker)
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
        width: LyricBarPopoverMetrics.size.width,
        height: LyricBarPopoverMetrics.size.height
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
        let raw = LyricBarStatusItemView.textOrigin
            + LyricBarStatusItemView.textWidth(lastTitle)
            + LyricBarStatusItemView.trailingInset
        // Rounded up so small changes don't nudge the whole menu bar on every lyric line.
        let width = min(max(ceil(raw / 16) * 16, Self.minStatusWidth), Self.maxStatusWidth)
        guard width != statusView.preferredWidth else { return }
        statusView.preferredWidth = width
        statusView.setFrameSize(NSSize(width: width, height: 22))
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
final class LyricBarWindows: NSObject, NSWindowDelegate {
    static let shared = LyricBarWindows()

    private var aboutWindow: NSWindow?

    func showAbout() {
        if let win = aboutWindow {
            win.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }

        let aboutVC = AboutViewController()
        let win = NSWindow(contentViewController: aboutVC)
        win.title = "About LyricBar"
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

        let title = NSTextField(labelWithString: "LyricBar")
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
