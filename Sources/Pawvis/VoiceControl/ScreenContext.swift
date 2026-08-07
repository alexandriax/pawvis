import AppKit
import ApplicationServices
import CoreGraphics
import Foundation
import ScreenCaptureKit
import Vision

/// One thing on screen a voice command could refer to.
struct ScreenTarget {
    enum Source: String { case accessibility, ocr }
    var label: String
    var role: String
    /// Global screen coordinates, top-left origin (AX/CGEvent space).
    var frame: CGRect
    var source: Source

    var center: CGPoint { CGPoint(x: frame.midX, y: frame.midY) }
}

/// What Pawvis can see around the pointer (or across the whole screen) at the
/// moment a command needs visual grounding.
struct ScreenContextSnapshot {
    enum Scope: String { case regionAroundPointer, fullScreen }

    var scope: Scope
    var pointer: CGPoint
    var regionOfInterest: CGRect
    var frontmostAppName: String?
    var frontmostBundleID: String?
    var windowTitle: String?
    var focusedElement: String?
    var targets: [ScreenTarget]
    /// False when the Screen Recording permission is missing (AX-only mode).
    var ocrAvailable: Bool

    /// Numbered target list for the language model. Coordinates are integer
    /// screen points so the model can reason about layout.
    var promptDescription: String {
        var lines: [String] = []
        if let app = frontmostAppName {
            lines.append("Frontmost app: \(app)")
        }
        if let title = windowTitle, !title.isEmpty {
            lines.append("Window: \(title)")
        }
        if let focused = focusedElement {
            lines.append("Focused element: \(focused)")
        }
        lines.append("Pointer position: (\(Int(pointer.x)), \(Int(pointer.y)))")
        lines.append("Visible elements (index. role “label” at x,y size w×h):")
        for (index, target) in targets.enumerated() {
            let f = target.frame
            lines.append(
                "\(index). \(target.role) “\(target.label)” at \(Int(f.minX)),\(Int(f.minY)) size \(Int(f.width))×\(Int(f.height))")
        }
        return lines.joined(separator: "\n")
    }
}

/// Captures what's on screen near the pointer: accessibility tree first
/// (labeled, actionable, pixel-accurate frames), OCR of a screenshot in
/// parallel (catches canvases, images, and unlabeled custom controls). Both
/// legs measured warm at well under 200 ms combined.
final class ScreenContextProvider {
    /// Size of the "near the pointer" region, in points.
    private static let regionSize = CGSize(width: 900, height: 600)
    /// Node-visit budget for one AX traversal (IPC is ~0.1–0.2 ms per
    /// attribute read; the budget caps worst-case latency, not typical).
    private static let axNodeBudget = 2500
    /// Raw collection cap during traversal, before curation.
    private static let maxRawTargets = 120
    /// Prompt-size caps. Prefill latency scales with prompt tokens (measured:
    /// a 50-element list costs ~10× the probe's small-prompt latency), so the
    /// first, near-the-pointer pass stays small; the full-screen escalation
    /// pass may carry more. The model's window is 4096 tokens total.
    private static func maxTargets(for scope: ScreenContextSnapshot.Scope) -> Int {
        scope == .regionAroundPointer ? 30 : 50
    }

    func snapshot(scope: ScreenContextSnapshot.Scope) async -> ScreenContextSnapshot {
        let pointer = CGEvent(source: nil)?.location ?? .zero
        let roi = Self.regionOfInterest(scope: scope, pointer: pointer)
        let frontmost = NSWorkspace.shared.frontmostApplication

        // The two legs are independent; run them concurrently.
        async let axLeg = Self.accessibilityTargets(
            pointer: pointer, roi: roi, frontmostPID: frontmost?.processIdentifier)
        async let ocrLeg = Self.ocrTargets(roi: roi)

        let ax = await axLeg
        let ocr = await ocrLeg

        var targets = ax.targets
        // OCR lines that duplicate an AX label add noise; keep the ones that
        // bring new text.
        let axLabels = Set(targets.map { $0.label.lowercased() })
        for target in ocr.targets where !axLabels.contains(target.label.lowercased()) {
            targets.append(target)
        }
        targets = Self.curate(targets, cap: Self.maxTargets(for: scope))

        return ScreenContextSnapshot(
            scope: scope,
            pointer: pointer,
            regionOfInterest: roi,
            frontmostAppName: frontmost?.localizedName,
            frontmostBundleID: frontmost?.bundleIdentifier,
            windowTitle: ax.windowTitle,
            focusedElement: ax.focusedDescription,
            targets: targets,
            ocrAvailable: ocr.available)
    }

    /// Every element in the prompt costs prefill latency, so spend the budget
    /// well: drop junk labels, put actionable controls before passive text,
    /// and collapse duplicate labels (web AX trees fragment one visual button
    /// into many static-text shards).
    private static let actionableRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXComboBox", "AXMenuItem", "AXTab", "AXSlider", "AXDisclosureTriangle",
    ]

    private static func curate(_ targets: [ScreenTarget], cap: Int) -> [ScreenTarget] {
        var seenLabels = Set<String>()
        var actionable: [ScreenTarget] = []
        var passive: [ScreenTarget] = []
        for target in targets {
            let label = target.label.trimmingCharacters(in: .whitespacesAndNewlines)
            guard label.count >= 2, label.contains(where: { $0.isLetter || $0.isNumber }) else {
                continue
            }
            let key = label.lowercased()
            guard !seenLabels.contains(key) else { continue }
            seenLabels.insert(key)
            var cleaned = target
            cleaned.label = label
            if actionableRoles.contains(target.role) {
                actionable.append(cleaned)
            } else {
                passive.append(cleaned)
            }
        }
        return Array((actionable + passive).prefix(cap))
    }

    // MARK: - Region

    private static func regionOfInterest(
        scope: ScreenContextSnapshot.Scope, pointer: CGPoint
    ) -> CGRect {
        let screens = NSScreen.screens
        // Screen bounds in top-left-origin global space (same as CGEvent).
        let primaryHeight = screens.first.map { $0.frame.maxY } ?? 0
        let screenFrames = screens.map { screen in
            CGRect(x: screen.frame.minX,
                   y: primaryHeight - screen.frame.maxY,
                   width: screen.frame.width,
                   height: screen.frame.height)
        }
        let containing = screenFrames.first { $0.contains(pointer) }
            ?? screenFrames.first ?? .zero

        switch scope {
        case .fullScreen:
            return containing
        case .regionAroundPointer:
            var rect = CGRect(
                x: pointer.x - regionSize.width / 2,
                y: pointer.y - regionSize.height / 2,
                width: regionSize.width,
                height: regionSize.height)
            // Clamp to the screen the pointer is on.
            rect.origin.x = max(containing.minX, min(rect.minX, containing.maxX - rect.width))
            rect.origin.y = max(containing.minY, min(rect.minY, containing.maxY - rect.height))
            return rect.intersection(containing)
        }
    }

    // MARK: - Accessibility leg

    private struct AXLegResult {
        var targets: [ScreenTarget] = []
        var windowTitle: String?
        var focusedDescription: String?
    }

    private static let interestingRoles: Set<String> = [
        "AXButton", "AXLink", "AXTextField", "AXTextArea", "AXSearchField",
        "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
        "AXComboBox", "AXMenuItem", "AXTab", "AXStaticText", "AXHeading",
        "AXSlider", "AXDisclosureTriangle", "AXImage", "AXCell", "AXRow",
    ]

    private static func accessibilityTargets(
        pointer: CGPoint, roi: CGRect, frontmostPID: pid_t?
    ) async -> AXLegResult {
        // AX calls are IPC and thread-safe; keep them off the main thread.
        await Task.detached(priority: .userInitiated) {
            var result = AXLegResult()

            // Hit-test to find the window under the pointer.
            let systemWide = AXUIElementCreateSystemWide()
            var hitElement: AXUIElement?
            var raw: AXUIElement?
            withUnsafeMutablePointer(to: &raw) { pointerOut in
                _ = AXUIElementCopyElementAtPosition(
                    systemWide, Float(pointer.x), Float(pointer.y), pointerOut)
            }
            hitElement = raw

            var window: AXUIElement? = hitElement.flatMap { windowContaining($0) }
            // Fallback: the frontmost app's focused window (system-wide
            // hit-tests can fail on some surfaces).
            if window == nil, let pid = frontmostPID {
                let appElement = AXUIElementCreateApplication(pid)
                window = copyAttribute(appElement, kAXFocusedWindowAttribute).map { $0 as! AXUIElement }
            }

            if let pid = frontmostPID {
                let appElement = AXUIElementCreateApplication(pid)
                // Focus must be queried app-level: the system-wide focused
                // element returns cannotComplete even for trusted processes.
                if let focusedRef = copyAttribute(appElement, kAXFocusedUIElementAttribute) {
                    let focused = focusedRef as! AXUIElement
                    let focusedRole = role(of: focused) ?? "?"
                    let focusedLabel = label(of: focused) ?? ""
                    result.focusedDescription = "\(focusedRole) “\(focusedLabel)”"
                }
            }

            guard let window else { return result }
            result.windowTitle = copyAttribute(window, kAXTitleAttribute) as? String

            // Bounded breadth-first traversal, pruned to the ROI.
            var queue: [AXUIElement] = [window]
            var visited = 0
            while !queue.isEmpty, visited < axNodeBudget, result.targets.count < maxRawTargets {
                let element = queue.removeFirst()
                visited += 1

                let elementFrame = frame(of: element)
                // Prune subtrees that can't intersect the ROI (a container's
                // frame bounds its children in practice).
                if let f = elementFrame, !f.isEmpty, !f.intersects(roi) {
                    continue
                }

                if let elementRole = role(of: element),
                   interestingRoles.contains(elementRole),
                   let f = elementFrame, f.intersects(roi),
                   let text = label(of: element), !text.isEmpty {
                    result.targets.append(ScreenTarget(
                        label: String(text.prefix(120)),
                        role: elementRole,
                        frame: f,
                        source: .accessibility))
                }
                queue.append(contentsOf: children(of: element))
            }
            return result
        }.value
    }

    private static func windowContaining(_ element: AXUIElement) -> AXUIElement? {
        if let window = copyAttribute(element, kAXWindowAttribute) {
            return (window as! AXUIElement)
        }
        // Walk up looking for a window role.
        var current: AXUIElement? = element
        for _ in 0..<15 {
            guard let c = current else { return nil }
            if role(of: c) == "AXWindow" { return c }
            current = copyAttribute(c, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        return nil
    }

    private static func copyAttribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, name as CFString, &value)
        return error == .success ? value : nil
    }

    private static func role(of element: AXUIElement) -> String? {
        copyAttribute(element, kAXRoleAttribute) as? String
    }

    private static func label(of element: AXUIElement) -> String? {
        if let title = copyAttribute(element, kAXTitleAttribute) as? String, !title.isEmpty {
            return title
        }
        if let description = copyAttribute(element, kAXDescriptionAttribute) as? String,
           !description.isEmpty {
            return description
        }
        if let value = copyAttribute(element, kAXValueAttribute) as? String, !value.isEmpty {
            return value
        }
        return nil
    }

    private static func frame(of element: AXUIElement) -> CGRect? {
        guard let value = copyAttribute(element, "AXFrame") else { return nil }
        var rect = CGRect.zero
        guard CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetValue(value as! AXValue, .cgRect, &rect) else { return nil }
        return rect
    }

    private static func children(of element: AXUIElement) -> [AXUIElement] {
        guard let value = copyAttribute(element, kAXChildrenAttribute) as? [AnyObject] else {
            return []
        }
        return value.map { $0 as! AXUIElement }
    }

    // MARK: - OCR leg

    private struct OCRLegResult {
        var targets: [ScreenTarget] = []
        var available = true
    }

    private static func ocrTargets(roi: CGRect) async -> OCRLegResult {
        guard CGPreflightScreenCaptureAccess() else {
            return OCRLegResult(available: false)
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(
                false, onScreenWindowsOnly: true)
            // The display whose bounds contain the ROI center (SCDisplay
            // frames are top-left-origin global, same space as the ROI).
            let center = CGPoint(x: roi.midX, y: roi.midY)
            guard let display = content.displays.first(where: { $0.frame.contains(center) })
                ?? content.displays.first else {
                return OCRLegResult(available: false)
            }

            let filter = SCContentFilter(display: display, excludingWindows: [])
            let configuration = SCStreamConfiguration()
            // Capture with a margin so words aren't sliced at the ROI edge.
            let margin: CGFloat = 60
            let capture = roi.insetBy(dx: -margin, dy: -margin)
                .intersection(display.frame)
            configuration.sourceRect = CGRect(
                x: capture.minX - display.frame.minX,
                y: capture.minY - display.frame.minY,
                width: capture.width,
                height: capture.height)
            configuration.width = Int(capture.width * 2)
            configuration.height = Int(capture.height * 2)
            configuration.showsCursor = false

            let image = try await SCScreenshotManager.captureImage(
                contentFilter: filter, configuration: configuration)

            let lines = try recognizeText(in: image)
            var targets: [ScreenTarget] = []
            for line in lines {
                // Vision boxes are normalized with a bottom-left origin; map
                // into top-left-origin global screen points.
                let box = line.box
                let screenFrame = CGRect(
                    x: capture.minX + box.minX * capture.width,
                    y: capture.minY + (1 - box.maxY) * capture.height,
                    width: box.width * capture.width,
                    height: box.height * capture.height)
                guard screenFrame.intersects(roi) else { continue }
                targets.append(ScreenTarget(
                    label: String(line.text.prefix(120)),
                    role: "text",
                    frame: screenFrame,
                    source: .ocr))
            }
            return OCRLegResult(targets: targets)
        } catch {
            Log.voice.warning("Screen capture for OCR failed: \(error.localizedDescription, privacy: .public)")
            return OCRLegResult(available: false)
        }
    }

    private static func recognizeText(in image: CGImage) throws -> [(text: String, box: CGRect)] {
        // .fast is ~10× quicker than .accurate (27 ms warm vs 300 ms) and its
        // errors are within fuzzy-match tolerance for target lookup.
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        return observations.compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return (candidate.string, observation.boundingBox)
        }
    }
}
