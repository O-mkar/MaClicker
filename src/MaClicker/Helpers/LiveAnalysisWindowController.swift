//
//  LiveAnalysisWindowController.swift
//  MaClicker
//

import Cocoa
import WebKit

/// Manages a floating always-on-top panel with a WKWebView showing
/// live CPS analysis and bot-detection scoring while the auto-clicker runs.
final class LiveAnalysisWindowController: NSObject {

    static let shared = LiveAnalysisWindowController()

    private var panel: NSPanel?
    private var webView: WKWebView?
    private var isSessionActive = false

    // Click batching — accumulate timestamps and flush every 100ms
    private var pendingClicks: [Double] = []
    private var batchTimer: Timer?

    private override init() {
        super.init()
    }

    // MARK: - Public API (called from AutoClicker)

    /// Show the panel and start a fresh analysis session.
    func startSession() {
        DispatchQueue.main.async { [self] in
            if panel == nil { createPanel() }
            panel?.orderFront(nil)
            isSessionActive = true
            pendingClicks = []

            // Start batch flush timer on main run loop
            batchTimer?.invalidate()
            batchTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
                self?.flushClicks()
            }

            webView?.evaluateJavaScript("startSession()", completionHandler: nil)
        }
    }

    /// Record a click timestamp (milliseconds since session start).
    /// Thread-safe — can be called from any queue.
    func recordClick(relativeMs: Double) {
        guard isSessionActive else { return }
        pendingClicks.append(relativeMs)
    }

    /// End the session — flush remaining clicks, run final analysis.
    func endSession() {
        DispatchQueue.main.async { [self] in
            isSessionActive = false
            batchTimer?.invalidate()
            batchTimer = nil
            flushClicks()
            webView?.evaluateJavaScript("endSession()", completionHandler: nil)
        }
    }

    /// Close the panel.
    func hideWindow() {
        DispatchQueue.main.async { [self] in
            panel?.orderOut(nil)
        }
    }

    // MARK: - Private

    /// Send accumulated click timestamps to the WebView in one batch.
    private func flushClicks() {
        guard !pendingClicks.isEmpty else { return }
        let batch = pendingClicks
        pendingClicks = []

        let json = "[" + batch.map { String(format: "%.3f", $0) }.joined(separator: ",") + "]"
        webView?.evaluateJavaScript("addClickBatch(\(json))", completionHandler: nil)
    }

    /// Create the floating NSPanel with WKWebView.
    private func createPanel() {
        let p = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 680),
            styleMask: [.titled, .closable, .resizable, .utilityWindow, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.title = "Live Click Analysis"
        p.level = .floating
        p.isMovableByWindowBackground = true
        p.isFloatingPanel = true
        p.hidesOnDeactivate = false
        p.minSize = NSSize(width: 380, height: 400)
        p.center()

        // Dark title bar
        p.backgroundColor = NSColor(red: 0.035, green: 0.05, blue: 0.094, alpha: 1)
        p.titlebarAppearsTransparent = true
        if #available(macOS 10.14, *) {
            p.appearance = NSAppearance(named: .darkAqua)
        }

        let config = WKWebViewConfiguration()
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")

        let wv = WKWebView(frame: p.contentView!.bounds, configuration: config)
        wv.autoresizingMask = [.width, .height]
        wv.setValue(false, forKey: "drawsBackground") // transparent bg
        p.contentView?.addSubview(wv)

        // Load bundled HTML
        if let htmlURL = Bundle.main.url(forResource: "analysis", withExtension: "html") {
            wv.loadFileURL(htmlURL, allowingReadAccessTo: htmlURL.deletingLastPathComponent())
        }

        self.panel = p
        self.webView = wv
    }
}
