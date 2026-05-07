import AppKit
import Foundation
import ImageIO

struct PhotoInfo {
    let width: Int
    let height: Int
    let format: String
    let fileSize: UInt64
    let metadata: [String: Any]
}

final class ImageWindow: NSWindow {
    var onKeyEvent: ((NSEvent) -> Bool)?

    override func keyDown(with event: NSEvent) {
        if onKeyEvent?(event) == true {
            return
        }

        super.keyDown(with: event)
    }
}

final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var bounds = super.constrainBoundsRect(proposedBounds)

        guard let documentView else {
            return bounds
        }

        let documentFrame = documentView.frame
        if documentFrame.width < bounds.width {
            bounds.origin.x = floor((documentFrame.width - bounds.width) / 2)
        }

        if documentFrame.height < bounds.height {
            bounds.origin.y = floor((documentFrame.height - bounds.height) / 2)
        }

        return bounds
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private var photoURLs: [URL] = []
    private var currentIndex = 0
    private let initialURL: URL?
    private var window: ImageWindow?
    private var scrollView: NSScrollView?
    private var imageView: NSImageView?
    private var zoomOverlayLabel: NSTextField?
    private var zoomOverlayHideWorkItem: DispatchWorkItem?
    private var infoWindow: NSWindow?
    private var keyEventMonitor: Any?
    private var currentImageSize = NSSize(width: 1, height: 1)
    private var zoomScale: CGFloat = 1
    private var usesAutomaticZoom = true
    private let infoWindowSize = NSSize(width: 520, height: 360)
    private let infoWindowGap: CGFloat = 12
    private let zoomStep: CGFloat = 0.15
    private let minimumZoomScale: CGFloat = 0.05
    private let maximumZoomScale: CGFloat = 8

    init(initialURL: URL?) {
        self.initialURL = initialURL
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu()
        installKeyEventMonitor()
        if let initialURL {
            openPhoto(at: initialURL)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func application(_ application: NSApplication, openFiles filenames: [String]) {
        guard let filename = filenames.first else {
            application.reply(toOpenOrPrint: .failure)
            return
        }

        let url = URL(fileURLWithPath: filename)
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url),
              image.isValid else {
            application.reply(toOpenOrPrint: .failure)
            return
        }

        openPhoto(at: url)
        application.reply(toOpenOrPrint: .success)
    }

    func windowWillClose(_ notification: Notification) {
        if notification.object as? NSWindow === window {
            NSApp.terminate(nil)
        }
    }

    private func buildMainMenu() {
        let mainMenu = NSMenu()
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let quitItem = NSMenuItem(
            title: "Quit Videre",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        appMenu.addItem(quitItem)
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        let actionsMenuItem = NSMenuItem()
        let actionsMenu = NSMenu(title: "Actions")
        actionsMenu.addItem(menuItem(title: "Previous Photo", action: #selector(previousPhotoAction), keyEquivalent: "\u{F702}"))
        actionsMenu.addItem(menuItem(title: "Next Photo", action: #selector(nextPhotoAction), keyEquivalent: "\u{F703}"))
        actionsMenu.addItem(.separator())
        actionsMenu.addItem(menuItem(title: "Zoom In", action: #selector(zoomInAction), keyEquivalent: "+"))
        actionsMenu.addItem(menuItem(title: "Zoom Out", action: #selector(zoomOutAction), keyEquivalent: "-"))
        actionsMenu.addItem(menuItem(title: "Zoom to 100%", action: #selector(zoomToActualSizeAction), keyEquivalent: "="))
        actionsMenu.addItem(.separator())
        actionsMenu.addItem(menuItem(title: "Toggle Full Screen", action: #selector(toggleFullScreenAction), keyEquivalent: "f"))
        actionsMenu.addItem(menuItem(title: "Photo Info", action: #selector(showInfoWindowAction), keyEquivalent: "i"))

        actionsMenuItem.submenu = actionsMenu
        mainMenu.addItem(actionsMenuItem)
        NSApp.mainMenu = mainMenu
    }

    private func menuItem(title: String, action: Selector, keyEquivalent: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: keyEquivalent)
        item.target = self
        return item
    }

    @objc private func previousPhotoAction() {
        showPreviousPhoto()
    }

    @objc private func nextPhotoAction() {
        showNextPhoto()
    }

    @objc private func zoomInAction() {
        zoomIn()
    }

    @objc private func zoomOutAction() {
        zoomOut()
    }

    @objc private func zoomToActualSizeAction() {
        zoomToActualSize()
    }

    @objc private func toggleFullScreenAction() {
        toggleFullScreen()
    }

    @objc private func showInfoWindowAction() {
        showInfoWindow()
    }

    private func openCurrentPhoto() {
        guard let image = NSImage(contentsOf: currentURL), image.isValid else {
            showLoadFailureAndQuit(currentURL.path)
        }

        let photoInfo = loadPhotoInfo(currentURL, fallbackImage: image)
        let screenFrame = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        currentImageSize = NSSize(width: photoInfo.width, height: photoInfo.height)

        if usesAutomaticZoom {
            zoomScale = automaticZoomScale(for: currentImageSize, in: screenFrame)
        }

        let displayedSize = displayedImageSize()
        let imageView = self.imageView ?? NSImageView(frame: NSRect(origin: .zero, size: displayedSize))
        imageView.image = image
        imageView.imageAlignment = .alignCenter
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.frame = NSRect(origin: .zero, size: displayedSize)
        self.imageView = imageView

        let scrollView = self.scrollView ?? makeScrollView(imageView: imageView)
        scrollView.documentView = imageView
        self.scrollView = scrollView

        let window = self.window ?? makeWindow(contentSize: windowContentSize(for: displayedSize, in: screenFrame), scrollView: scrollView)
        window.title = currentURL.lastPathComponent

        applyZoomToWindow(window, screenFrame: screenFrame)

        window.makeKeyAndOrderFront(nil)
        self.window = window

        if let infoWindow, infoWindow.isVisible {
            updateInfoWindowContent()
            positionInfoWindow(infoWindow)
            keepInfoWindowAbovePhotoWindow(infoWindow)
        }
    }

    private func makeScrollView(imageView: NSImageView) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(origin: .zero, size: imageView.frame.size))
        scrollView.contentView = CenteringClipView()
        scrollView.documentView = imageView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        return scrollView
    }

    private func makeWindow(contentSize: NSSize, scrollView: NSScrollView) -> ImageWindow {
        let styleMask: NSWindow.StyleMask = [.titled, .closable, .miniaturizable, .resizable]
        let window = ImageWindow(
            contentRect: NSRect(origin: .zero, size: contentSize),
            styleMask: styleMask,
            backing: .buffered,
            defer: false
        )

        window.delegate = self
        window.contentView = makePhotoContentView(contentSize: contentSize, scrollView: scrollView)
        window.onKeyEvent = { [weak self] event in
            self?.handleKeyEvent(event) ?? false
        }
        return window
    }

    private func makePhotoContentView(contentSize: NSSize, scrollView: NSScrollView) -> NSView {
        let contentView = NSView(frame: NSRect(origin: .zero, size: contentSize))

        scrollView.frame = contentView.bounds
        scrollView.autoresizingMask = [.width, .height]
        contentView.addSubview(scrollView)

        let label = NSTextField(labelWithString: "")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.isHidden = true
        label.alignment = .center
        label.font = .monospacedDigitSystemFont(ofSize: 14, weight: .semibold)
        label.textColor = .white
        label.wantsLayer = true
        label.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.72).cgColor
        label.layer?.cornerRadius = 6
        label.layer?.masksToBounds = true
        contentView.addSubview(label)

        NSLayoutConstraint.activate([
            label.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 12),
            label.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -12),
            label.widthAnchor.constraint(greaterThanOrEqualToConstant: 68),
            label.heightAnchor.constraint(equalToConstant: 32)
        ])

        zoomOverlayLabel = label
        return contentView
    }

    private func installKeyEventMonitor() {
        keyEventMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else {
                return event
            }

            return self.handleKeyEvent(event) ? nil : event
        }
    }

    private func handleKeyEvent(_ event: NSEvent) -> Bool {
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            NSApp.terminate(nil)
            return true
        }

        switch event.keyCode {
        case 53:
            NSApp.terminate(nil)
            return true
        case 123:
            guard photoURLs.isEmpty == false else {
                return true
            }
            showPreviousPhoto()
            return true
        case 124:
            guard photoURLs.isEmpty == false else {
                return true
            }
            showNextPhoto()
            return true
        default:
            switch event.characters?.lowercased() ?? event.charactersIgnoringModifiers?.lowercased() {
            case "i":
                showInfoWindow()
                return true
            case "+":
                zoomIn()
                return true
            case "-":
                zoomOut()
                return true
            case "=":
                zoomToActualSize()
                return true
            case "f":
                toggleFullScreen()
                return true
            default:
                break
            }
        }

        return false
    }

    private var currentURL: URL {
        photoURLs[currentIndex]
    }

    private func openPhoto(at url: URL) {
        photoURLs = discoverPhotos(around: url)
        currentIndex = photoURLs.firstIndex(of: url) ?? 0
        usesAutomaticZoom = true
        openCurrentPhoto()
    }

    private func showNextPhoto() {
        guard photoURLs.isEmpty == false else {
            return
        }

        currentIndex = (currentIndex + 1) % photoURLs.count
        openCurrentPhoto()
    }

    private func showPreviousPhoto() {
        guard photoURLs.isEmpty == false else {
            return
        }

        currentIndex = (currentIndex - 1 + photoURLs.count) % photoURLs.count
        openCurrentPhoto()
    }

    private func zoomIn() {
        usesAutomaticZoom = false
        zoomScale = clamp(zoomScale * (1 + zoomStep), min: minimumZoomScale, max: maximumZoomScale)
        applyZoomToCurrentPhoto()
        showZoomOverlay()
    }

    private func zoomOut() {
        usesAutomaticZoom = false
        zoomScale = clamp(zoomScale * (1 - zoomStep), min: minimumZoomScale, max: maximumZoomScale)
        applyZoomToCurrentPhoto()
        showZoomOverlay()
    }

    private func zoomToActualSize() {
        usesAutomaticZoom = false
        zoomScale = 1
        applyZoomToCurrentPhoto()
        showZoomOverlay()
    }

    private func toggleFullScreen() {
        window?.toggleFullScreen(nil)
    }

    private func applyZoomToCurrentPhoto() {
        guard let window else {
            return
        }

        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1024, height: 768)
        applyZoomToWindow(window, screenFrame: screenFrame)
        positionInfoWindowIfVisible()
    }

    private func showZoomOverlay() {
        guard let zoomOverlayLabel else {
            return
        }

        zoomOverlayHideWorkItem?.cancel()
        zoomOverlayLabel.stringValue = "\(Int(round(zoomScale * 100)))%"
        zoomOverlayLabel.isHidden = false
        zoomOverlayLabel.alphaValue = 1

        let hideWorkItem = DispatchWorkItem { [weak self] in
            self?.zoomOverlayLabel?.isHidden = true
        }

        zoomOverlayHideWorkItem = hideWorkItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: hideWorkItem)
    }

    private func applyZoomToWindow(_ window: NSWindow, screenFrame: NSRect) {
        let displayedSize = displayedImageSize()
        imageView?.frame = NSRect(origin: .zero, size: displayedSize)

        if window.styleMask.contains(.fullScreen) {
            scrollView?.reflectScrolledClipView(scrollView?.contentView ?? NSClipView())
            return
        }

        if usesAutomaticZoom && zoomScale < 1 {
            window.setFrame(screenFrame, display: true)
        } else if displayedSize.width > screenFrame.width || displayedSize.height > screenFrame.height {
            window.setFrame(screenFrame, display: true)
        } else {
            window.setContentSize(windowContentSize(for: displayedSize, in: screenFrame))
            window.center()
        }
    }

    private func displayedImageSize() -> NSSize {
        NSSize(
            width: max(1, currentImageSize.width * zoomScale),
            height: max(1, currentImageSize.height * zoomScale)
        )
    }

    private func windowContentSize(for displayedSize: NSSize, in screenFrame: NSRect) -> NSSize {
        NSSize(
            width: min(displayedSize.width, screenFrame.width),
            height: min(displayedSize.height, screenFrame.height)
        )
    }

    private func automaticZoomScale(for imageSize: NSSize, in screenFrame: NSRect) -> CGFloat {
        guard imageSize.width > 0, imageSize.height > 0 else {
            return 1
        }

        return min(1, min(screenFrame.width / imageSize.width, screenFrame.height / imageSize.height))
    }

    private func showInfoWindow() {
        if let infoWindow, infoWindow.isVisible {
            infoWindow.close()
            self.infoWindow = nil
            window?.makeKey()
            return
        }

        guard let image = imageView?.image else {
            return
        }

        let info = loadPhotoInfo(currentURL, fallbackImage: image)
        let infoWindow = self.infoWindow ?? NSPanel(
            contentRect: NSRect(origin: .zero, size: infoWindowSize),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        infoWindow.title = "Photo Info"
        infoWindow.level = .floating
        infoWindow.contentView = makeInfoContentView(info: info)
        positionInfoWindow(infoWindow)
        keepInfoWindowAbovePhotoWindow(infoWindow)
        infoWindow.orderFront(nil)
        window?.makeKey()
        self.infoWindow = infoWindow
    }

    private func positionInfoWindowIfVisible() {
        guard let infoWindow, infoWindow.isVisible else {
            return
        }

        positionInfoWindow(infoWindow)
        keepInfoWindowAbovePhotoWindow(infoWindow)
    }

    private func updateInfoWindowContent() {
        guard let image = imageView?.image, let infoWindow else {
            return
        }

        let info = loadPhotoInfo(currentURL, fallbackImage: image)
        infoWindow.contentView = makeInfoContentView(info: info)
    }

    private func makeInfoContentView(info: PhotoInfo) -> NSView {
        let tabView = NSTabView(frame: NSRect(origin: .zero, size: infoWindowSize))
        tabView.autoresizingMask = [.width, .height]
        tabView.addTabViewItem(makeSummaryTab(info: info))
        tabView.addTabViewItem(makeExifTab(info: info))

        let contentView = NSView(frame: NSRect(origin: .zero, size: infoWindowSize))
        contentView.addSubview(tabView)
        return contentView
    }

    private func positionInfoWindow(_ infoWindow: NSWindow) {
        guard let window else {
            infoWindow.center()
            return
        }

        let screenFrame = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame
        guard let screenFrame else {
            infoWindow.center()
            return
        }

        let imageFrame = window.frame
        let rightX = imageFrame.maxX + infoWindowGap
        let origin: NSPoint

        if rightX + infoWindowSize.width <= screenFrame.maxX {
            origin = NSPoint(
                x: rightX,
                y: clamp(
                    imageFrame.maxY - infoWindowSize.height,
                    min: screenFrame.minY,
                    max: screenFrame.maxY - infoWindowSize.height
                )
            )
        } else {
            origin = NSPoint(
                x: screenFrame.maxX - infoWindowSize.width,
                y: screenFrame.maxY - infoWindowSize.height
            )
        }

        infoWindow.setFrame(NSRect(origin: origin, size: infoWindowSize), display: true)
    }

    private func keepInfoWindowAbovePhotoWindow(_ infoWindow: NSWindow) {
        guard let window else {
            return
        }

        if infoWindow.parent !== window {
            window.addChildWindow(infoWindow, ordered: .above)
        }
    }

    private func makeSummaryTab(info: PhotoInfo) -> NSTabViewItem {
        let textView = readOnlyTextView(text: """
        Width: \(info.width) px
        Height: \(info.height) px
        File format: \(info.format)
        File size: \(formatByteCount(info.fileSize))
        """)
        let item = NSTabViewItem(identifier: "summary")
        item.label = "Summary"
        item.view = scrollView(containing: textView)
        return item
    }

    private func makeExifTab(info: PhotoInfo) -> NSTabViewItem {
        let item = NSTabViewItem(identifier: "exif")
        item.label = "EXIF"
        item.view = scrollView(containing: readOnlyTextView(text: exifText(from: info.metadata)))
        return item
    }

    private func readOnlyTextView(text: String) -> NSTextView {
        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 500, height: 320))
        textView.string = text
        textView.isEditable = false
        textView.isSelectable = false
        textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        textView.textContainerInset = NSSize(width: 12, height: 12)
        return textView
    }

    private func scrollView(containing textView: NSTextView) -> NSScrollView {
        let scrollView = NSScrollView(frame: NSRect(x: 0, y: 0, width: infoWindowSize.width, height: 332))
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        return scrollView
    }
}

func clamp(_ value: CGFloat, min: CGFloat, max: CGFloat) -> CGFloat {
    Swift.max(min, Swift.min(value, max))
}

func discoverPhotos(around initialURL: URL) -> [URL] {
    let directoryURL = initialURL.deletingLastPathComponent()
    let contents = (try? FileManager.default.contentsOfDirectory(
        at: directoryURL,
        includingPropertiesForKeys: nil,
        options: [.skipsHiddenFiles]
    )) ?? []

    let photos = contents
        .filter { $0.hasDirectoryPath == false && isSupportedImageURL($0) }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

    if photos.contains(initialURL) {
        return photos
    }

    return (photos + [initialURL])
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
}

func isSupportedImageURL(_ url: URL) -> Bool {
    imageTypes().contains(url.pathExtension.lowercased())
}

func imageTypes() -> [String] {
    [
        "avif", "bmp", "gif", "heic", "heif", "jpeg", "jpg", "png", "tif", "tiff", "webp"
    ]
}

func loadPhotoInfo(_ url: URL, fallbackImage: NSImage) -> PhotoInfo {
    let source = CGImageSourceCreateWithURL(url as CFURL, nil)
    let properties = source.flatMap {
        CGImageSourceCopyPropertiesAtIndex($0, 0, nil) as? [String: Any]
    } ?? [:]

    let width = properties[kCGImagePropertyPixelWidth as String] as? Int ?? Int(fallbackImage.size.width)
    let height = properties[kCGImagePropertyPixelHeight as String] as? Int ?? Int(fallbackImage.size.height)
    let format = source.flatMap { CGImageSourceGetType($0) as String? }
        .map(displayFormat)
        ?? url.pathExtension.uppercased()
    let fileSize = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? NSNumber)?.uint64Value ?? 0

    return PhotoInfo(width: width, height: height, format: format, fileSize: fileSize, metadata: properties)
}

func displayFormat(_ typeIdentifier: String) -> String {
    switch typeIdentifier {
    case "public.jpeg":
        return "JPEG"
    case "public.png":
        return "PNG"
    case "com.compuserve.gif":
        return "GIF"
    case "public.tiff":
        return "TIFF"
    case "org.webmproject.webp":
        return "WebP"
    case "public.heic":
        return "HEIC"
    case "public.heif":
        return "HEIF"
    default:
        return typeIdentifier
    }
}

func formatByteCount(_ byteCount: UInt64) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
}

func exifText(from metadata: [String: Any]) -> String {
    let exif = metadata[kCGImagePropertyExifDictionary as String] as? [String: Any] ?? [:]
    guard exif.isEmpty == false else {
        return "No EXIF data found."
    }

    return flattenDictionary(exif)
        .map { "\($0.key): \($0.value)" }
        .joined(separator: "\n")
}

func flattenDictionary(_ dictionary: [String: Any], prefix: String = "") -> [(key: String, value: String)] {
    dictionary.keys.sorted().flatMap { key -> [(key: String, value: String)] in
        let fullKey = prefix.isEmpty ? key : "\(prefix).\(key)"
        if let nested = dictionary[key] as? [String: Any] {
            return flattenDictionary(nested, prefix: fullKey)
        }

        return [(fullKey, String(describing: dictionary[key] ?? ""))]
    }
}

func showLoadFailureAndQuit(_ path: String) -> Never {
    let alert = NSAlert()
    alert.messageText = "Could not load image"
    alert.informativeText = path
    alert.runModal()
    NSApp.terminate(nil)
    exit(65)
}

func printUsageError() -> Never {
    FileHandle.standardError.write(Data("Error: expected one image filename argument, or --list-fileformats.\n".utf8))
    exit(64)
}

func printFileError(_ path: String) -> Never {
    FileHandle.standardError.write(Data("Error: file does not exist: \(path)\n".utf8))
    exit(66)
}

func printImageError(_ path: String) -> Never {
    FileHandle.standardError.write(Data("Error: could not load image: \(path)\n".utf8))
    exit(65)
}

let arguments = CommandLine.arguments.dropFirst()
let launchedFromAppBundle = Bundle.main.bundlePath.hasSuffix(".app")
let initialURL: URL?

if arguments.count == 1, arguments.first == "--list-fileformats" {
    FileHandle.standardOutput.write(Data((imageTypes().joined(separator: "\n") + "\n").utf8))
    exit(0)
} else if arguments.isEmpty && launchedFromAppBundle {
    initialURL = nil
} else if arguments.count == 1, let path = arguments.first {
    guard FileManager.default.fileExists(atPath: path) else {
        printFileError(path)
    }

    let fileURL = URL(fileURLWithPath: path)
    guard let image = NSImage(contentsOf: fileURL), image.isValid else {
        printImageError(path)
    }

    initialURL = fileURL
} else {
    printUsageError()
}

let app = NSApplication.shared
let appDelegate = AppDelegate(initialURL: initialURL)
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()
