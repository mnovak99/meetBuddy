import CoreGraphics
import Foundation
import ScreenCaptureKit

/// Every few seconds takes a screenshot of the meeting window and saves it as a JPEG when its
/// content changed noticeably and then stayed still (shared slides, code, dashboards).
/// Content that keeps moving (camera tiles, a playing video, scrolling) is skipped until it settles.
///
/// Uses ScreenCaptureKit with a single-window filter (`SCContentFilter(desktopIndependentWindow:)`):
/// works when the window is covered by other windows, not when it is minimized.
/// Needs the Screen Recording permission the app already has for window titles.
final class FrameCapturer {
    struct SavedFrame {
        /// Relative to the recording folder, e.g. "frames/142803.jpg".
        var file: String
        var capturedAt: Date
    }

    enum CaptureError: Error {
        case windowNotFound
        case blankImage
    }

    var onFrameSaved: ((SavedFrame) -> Void)?
    /// Called once when the window stops being capturable (minimized, closed), and when it is back.
    var onAvailabilityChanged: ((_ available: Bool) -> Void)?

    private(set) var windowID: CGWindowID
    private let framesDirectory: URL
    private let interval: TimeInterval
    private let maxDimension: Int
    private let changeThreshold: Double

    private var task: Task<Void, Never>?
    private var cachedWindow: SCWindow?
    private var lastSavedHash: PerceptualHash?
    /// Hash of the previous capture (a few seconds ago), to tell still content from moving content.
    private var previousHash: PerceptualHash?
    private var consecutiveFailures = 0
    private var isUnavailable = false

    init(windowID: CGWindowID, framesDirectory: URL, interval: TimeInterval, maxDimension: Int, changeThreshold: Double) {
        self.windowID = windowID
        self.framesDirectory = framesDirectory
        self.interval = interval
        self.maxDimension = maxDimension
        self.changeThreshold = changeThreshold
    }

    func start() {
        task?.cancel()
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.captureOnce()
                try? await Task.sleep(for: .seconds(self?.interval ?? 2.5))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// The user picked another window in the menu.
    func switchWindow(to id: CGWindowID) {
        windowID = id
        cachedWindow = nil
        lastSavedHash = nil
        previousHash = nil
    }

    private func captureOnce() async {
        do {
            let image = try await capture()
            guard let hash = PerceptualHash(image), !hash.isBlank else { throw CaptureError.blankImage }
            consecutiveFailures = 0
            if isUnavailable {
                isUnavailable = false
                onAvailabilityChanged?(true)
            }
            let shouldSave = FrameSelection.shouldSave(
                hash, previous: previousHash, lastSaved: lastSavedHash, changeThreshold: changeThreshold)
            previousHash = hash
            guard shouldSave else { return }
            let frame = try save(image)
            lastSavedHash = hash
            onFrameSaved?(frame)
        } catch {
            consecutiveFailures += 1
            cachedWindow = nil  // look the window up again next time
            // Two failures in a row (~5 s) = the window is really gone, not just a hiccup.
            if consecutiveFailures == 2 && !isUnavailable {
                isUnavailable = true
                Log.recording.notice("Meeting window cannot be captured: \(String(describing: error), privacy: .public)")
                onAvailabilityChanged?(false)
            }
        }
    }

    private func capture() async throws -> CGImage {
        let window = try await currentWindow()
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let configuration = SCStreamConfiguration()
        let size = ImageFiles.scaledSize(
            points: filter.contentRect.size, pixelScale: CGFloat(filter.pointPixelScale), maxDimension: maxDimension)
        configuration.width = Int(size.width)
        configuration.height = Int(size.height)
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        configuration.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// ScreenCaptureKit needs its own window object; find it by the window server ID once and reuse it.
    private func currentWindow() async throws -> SCWindow {
        if let cachedWindow {
            return cachedWindow
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let window = content.windows.first(where: { $0.windowID == windowID }) else {
            throw CaptureError.windowNotFound
        }
        cachedWindow = window
        return window
    }

    /// frames/HHmmss.jpg (wall-clock time, matches the note's attachment names).
    private func save(_ image: CGImage) throws -> SavedFrame {
        let now = Date()
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HHmmss"
        let base = formatter.string(from: now)
        var name = "\(base).jpg"
        var suffix = 2
        while FileManager.default.fileExists(atPath: framesDirectory.appending(path: name).path(percentEncoded: false)) {
            name = "\(base)-\(suffix).jpg"
            suffix += 1
        }
        try ImageFiles.writeJPEG(image, to: framesDirectory.appending(path: name))
        return SavedFrame(file: "frames/\(name)", capturedAt: now)
    }
}
