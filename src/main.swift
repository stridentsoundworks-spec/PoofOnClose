import Cocoa
import QuartzCore
import AVFoundation
import ServiceManagement

// MARK: - Preferences

struct Preferences {
    enum Theme: String, CaseIterable {
        case cloud   = "☁️ Classic Cloud"
        case pow     = "💥 Comic POW"
        case sparkle = "✨ Sparkle"
        case ripple  = "🌊 Ripple"
    }

    enum PositionMode: String, CaseIterable {
        case mouse  = "At Cursor"
        case window = "At Window"
    }

    private static let defaults = UserDefaults.standard

    static var theme: Theme {
        get { Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .cloud }
        set { defaults.set(newValue.rawValue, forKey: "theme") }
    }

    static var positionMode: PositionMode {
        get { PositionMode(rawValue: defaults.string(forKey: "positionMode") ?? "") ?? .mouse }
        set { defaults.set(newValue.rawValue, forKey: "positionMode") }
    }

    static var volume: Float {
        get {
            let v = defaults.float(forKey: "volume")
            return (v == 0 && !defaults.contains(key: "volume")) ? 0.7 : v
        }
        set { defaults.set(newValue, forKey: "volume") }
    }

    static var launchAtLogin: Bool {
        get { defaults.bool(forKey: "launchAtLogin") }
        set { defaults.set(newValue, forKey: "launchAtLogin") }
    }

    static var customSkipApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "customSkipApps") ?? []) }
        set { defaults.set(Array(newValue), forKey: "customSkipApps") }
    }

    static var allowedApps: Set<String> {
        get { Set(defaults.stringArray(forKey: "allowedApps") ?? []) }
        set { defaults.set(Array(newValue), forKey: "allowedApps") }
    }
}

extension UserDefaults {
    func contains(key: String) -> Bool { object(forKey: key) != nil }
}

// MARK: - Window Tracker

// All mutable state lives behind `stateQueue` (private serial queue).
// NSWorkspace notification callbacks are bounced onto stateQueue before
// touching any state, so the polling loop and notifications never race.
//
// Detection strategy: CGWindowListCopyWindowInfo polling at 50 ms.
// To reduce false positives from minimize / Space transitions, a window
// must be absent for the full gracePeriod AND the tracker must not be in
// a cooldown period. Minimized windows are detected by checking whether
// the owning app still has on-screen windows; if the app is still alive
// with visible windows the poof is suppressed.

final class WindowTracker {
    static let shared = WindowTracker()

    // All access to these must happen on stateQueue
    private var knownWindows:  [CGWindowID: WindowInfo] = [:]
    private var pendingPoofs:  [CGWindowID: PendingPoof] = [:]
    private var recentlyPoofed: Set<CGWindowID> = []
    private var lastSpaceSwitchTime: Date = .distantPast
    private var lastActiveApp: String = ""
    private var appSwitchTime: Date = .distantPast

    private let stateQueue = DispatchQueue(label: "com.theo.poofonclose.tracker", qos: .userInteractive)
    private var pollTimer: DispatchSourceTimer?
    private var observerTokens: [Any] = []  // block-based observer tokens for correct removal

    private let gracePeriod: TimeInterval = 0.06    // 60 ms — gives minimize animation time to register
    private let spaceSwitchCooldown: TimeInterval = 1.0
    private let appSwitchCooldown: TimeInterval = 0.5

    private let builtInSkipApps: Set<String> = [
        "WindowServer", "Dock", "SystemUIServer", "Control Center",
        "Notification Center", "PoofOnClose", "Spotlight", "Alfred",
        "Raycast", "Bartender", "CleanShot X", "Dropzone", "PopClip",
        "TextExpander", "Keyboard Maestro", "BetterTouchTool",
        "1Password", "Bitwarden", "LastPass", "Pastebot", "Paste",
        "Contexts", "AltTab", "Mission Control", "launchservicesd"
    ]

    private var effectiveSkipApps: Set<String> {
        builtInSkipApps.union(Preferences.customSkipApps).subtracting(Preferences.allowedApps)
    }

    struct WindowInfo {
        let bounds: CGRect
        let owner: String
        let pid: pid_t
    }

    struct PendingPoof {
        let bounds: CGRect
        let owner: String
        let pid: pid_t
        let time: Date
    }

    // MARK: Start / Stop

    func start() {
        // Bounce all notification mutations onto stateQueue
        let nc = NSWorkspace.shared.notificationCenter
        observerTokens.append(nc.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.stateQueue.async { self?.handleSpaceDidChange() }
        })
        observerTokens.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: nil) { [weak self] n in
            self?.stateQueue.async { self?.handleAppDidActivate(n) }
        })
        observerTokens.append(nc.addObserver(forName: NSWorkspace.didHideApplicationNotification, object: nil, queue: nil) { [weak self] n in
            self?.stateQueue.async { self?.handleAppDidHide(n) }
        })
        observerTokens.append(nc.addObserver(forName: NSWorkspace.didUnhideApplicationNotification, object: nil, queue: nil) { [weak self] n in
            self?.stateQueue.async { self?.handleAppDidUnhide(n) }
        })

        // Timer fires on stateQueue — no separate queue hop needed
        let timer = DispatchSource.makeTimerSource(queue: stateQueue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.pollWindows() }
        timer.resume()
        pollTimer = timer

        print("✅ WindowTracker started (serial stateQueue, 60 ms grace)")
    }

    func stop() {
        pollTimer?.cancel()
        pollTimer = nil
        let nc = NSWorkspace.shared.notificationCenter
        observerTokens.forEach { nc.removeObserver($0) }
        observerTokens.removeAll()
    }

    // MARK: Notification handlers (always on stateQueue)

    private func handleSpaceDidChange() {
        lastSpaceSwitchTime = Date()
        pendingPoofs.removeAll()
    }

    private func handleAppDidActivate(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let name = app.localizedName, name != lastActiveApp else { return }
        lastActiveApp = name
        appSwitchTime = Date()
        // Cancel poofs for apps we just switched away from — they likely just lost focus
        pendingPoofs = pendingPoofs.filter { $0.value.owner == name }
    }

    private func handleAppDidHide(_ n: Notification) {
        guard let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              let name = app.localizedName else { return }
        // ⌘H hide — cancel any pending poofs for this app
        pendingPoofs = pendingPoofs.filter { $0.value.owner != name }
    }

    private func handleAppDidUnhide(_ n: Notification) {
        // Nothing needed — windows will reappear in next poll cycle and cancel their pending poofs naturally
    }

    // MARK: Cooldown check (on stateQueue)

    private var isInCooldown: Bool {
        let now = Date()
        return now.timeIntervalSince(lastSpaceSwitchTime) < spaceSwitchCooldown
            || now.timeIntervalSince(appSwitchTime) < appSwitchCooldown
    }

    // MARK: Poll (on stateQueue)

    private func pollWindows() {
        let skip = effectiveSkipApps
        let options = CGWindowListOption([.excludeDesktopElements, .optionOnScreenOnly])
        guard let rawList = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else { return }

        var currentWindows: [CGWindowID: WindowInfo] = [:]

        for window in rawList {
            guard
                let windowID   = window[kCGWindowNumber as String] as? CGWindowID,
                let cfBoundsRaw = window[kCGWindowBounds as String] as? NSDictionary,
                let cfBounds   = cfBoundsRaw as CFDictionary?,
                let bounds     = CGRect(dictionaryRepresentation: cfBounds),
                let layer      = window[kCGWindowLayer as String] as? Int,
                let ownerName  = window[kCGWindowOwnerName as String] as? String,
                let ownerPID   = window[kCGWindowOwnerPID as String] as? pid_t,
                layer == 0
            else { continue }

            if skip.contains(ownerName) { continue }
            if ownerName.hasSuffix("Agent") || ownerName.hasSuffix("Helper") ||
               ownerName.hasPrefix("com.")  || ownerName.contains("Extension") { continue }

            // Ignore tiny floaters (tooltips, drop-shadows, panels)
            if bounds.width < 100 || bounds.height < 100 { continue }

            currentWindows[windowID] = WindowInfo(bounds: bounds, owner: ownerName, pid: ownerPID)
        }

        // Window reappeared — cancel pending poof
        for windowID in currentWindows.keys { pendingPoofs.removeValue(forKey: windowID) }

        // Window disappeared — queue poof if not in cooldown
        if !isInCooldown {
            for (windowID, info) in knownWindows {
                guard currentWindows[windowID] == nil,
                      !recentlyPoofed.contains(windowID),
                      pendingPoofs[windowID] == nil
                else { continue }
                pendingPoofs[windowID] = PendingPoof(bounds: info.bounds, owner: info.owner, pid: info.pid, time: Date())
            }
        }

        // Fire poofs that have passed grace period
        // Collect IDs first to avoid mutating the dictionary during iteration
        let now = Date()
        let readyIDs = pendingPoofs.compactMap { id, pending -> CGWindowID? in
            now.timeIntervalSince(pending.time) >= gracePeriod ? id : nil
        }

        for windowID in readyIDs {
            guard let pending = pendingPoofs.removeValue(forKey: windowID) else { continue }

            // Suppress if the app is still running and has other on-screen windows
            // (strongly suggests minimize rather than close)
            let appStillHasWindows = currentWindows.values.contains { $0.pid == pending.pid }
            // If the app itself has fully quit, appStillHasWindows will be false — fire the poof.
            // If the app is still alive with visible windows, it's ambiguous but allow it
            // (user closed one of many windows). Only suppress if the app has NO remaining windows
            // AND we know it's still running — that's the minimize signature.
            // NSRunningApplication must be queried on the main thread; read synchronously.
            var appIsRunning = false
            DispatchQueue.main.sync { appIsRunning = NSRunningApplication(processIdentifier: pending.pid) != nil }
            if appIsRunning && !appStillHasWindows {
                // App is alive but all its on-screen windows are gone — likely minimized or hidden.
                // Suppress to avoid false poof.
                // Exception: if knownWindows only ever had ONE window for this PID, it's probably a real close.
                let hadMultipleWindows = knownWindows.values.filter { $0.pid == pending.pid }.count > 1
                if !hadMultipleWindows {
                    // Single-window app that quit or closed — fire
                } else {
                    // Multi-window app with all windows gone while still alive — skip
                    continue
                }
            }

            recentlyPoofed.insert(windowID)
            let bounds = pending.bounds
            DispatchQueue.main.async {
                PoofAnimator.shared.showPoof(at: bounds)
            }
            // Clean up recentlyPoofed on our own stateQueue — no races
            stateQueue.asyncAfter(deadline: .now() + 2.0) { [weak self] in
                self?.recentlyPoofed.remove(windowID)
            }
        }

        knownWindows = currentWindows
    }
}

// MARK: - Multi-monitor coordinate helper

/// Converts a CGWindowList rect (Quartz global coordinates, top-left origin, y increases downward)
/// into AppKit screen coordinates (bottom-left origin, y increases upward) on the correct display.
func appKitPoint(forCGRect cgRect: CGRect) -> CGPoint {
    // Quartz global origin is the top-left of the primary display.
    // NSScreen frames use a flipped global space: origin is bottom-left of primary,
    // y increases upward. The primary display height bridges the two.
    //
    // Find the NSScreen whose frame contains the centre of the window.
    // NSScreen frames are already in AppKit (flipped) coordinates, so we must
    // convert the CG centre first using the primary screen height, then find the match.

    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0

    // Centre of the window in AppKit global coordinates
    let appKitCentre = CGPoint(
        x: cgRect.midX,
        y: primaryHeight - cgRect.midY
    )

    // Find which screen this centre sits on (or fall back to main)
    let targetScreen = NSScreen.screens.first { $0.frame.contains(appKitCentre) }
                    ?? NSScreen.main
                    ?? NSScreen.screens[0]

    return appKitCentre
}

// MARK: - Poof Animator

final class PoofAnimator {
    static let shared = PoofAnimator()
    private var activeWindows: [PoofWindow] = []

    /// `cgWindowRect` is a rect from CGWindowListCopyWindowInfo (top-left origin).
    func showPoof(at cgWindowRect: CGRect) {
        // Dynamic size: scale 140–320 px based on closed window area
        let area = cgWindowRect.width * cgWindowRect.height
        let normalised = min(1.0, area / (1440.0 * 900.0))
        let poofSize = CGFloat(140 + normalised * 180)

        let centre: CGPoint
        switch Preferences.positionMode {
        case .mouse:
            centre = NSEvent.mouseLocation
        case .window:
            centre = appKitPoint(forCGRect: cgWindowRect)
        }

        let origin = CGPoint(x: centre.x - poofSize / 2, y: centre.y - poofSize / 2)
        let nsRect = CGRect(origin: origin, size: CGSize(width: poofSize, height: poofSize))

        let poofWindow = PoofWindow(contentRect: nsRect, theme: Preferences.theme)
        activeWindows.append(poofWindow)
        poofWindow.onClose = { [weak self] w in self?.activeWindows.removeAll { $0 === w } }
        poofWindow.showPoof()
    }

    /// Convenience entry point for test callers that already have an AppKit-space centre point.
    /// Always spawns the poof at the given AppKit point regardless of the position mode preference.
    func showPoofAt(appKitCentre: CGPoint, approximateWindowSize: CGSize) {
        let area = approximateWindowSize.width * approximateWindowSize.height
        let normalised = min(1.0, area / (1440.0 * 900.0))
        let poofSize = CGFloat(140 + normalised * 180)
        let origin = CGPoint(x: appKitCentre.x - poofSize / 2, y: appKitCentre.y - poofSize / 2)
        let nsRect = CGRect(origin: origin, size: CGSize(width: poofSize, height: poofSize))
        let poofWindow = PoofWindow(contentRect: nsRect, theme: Preferences.theme)
        activeWindows.append(poofWindow)
        poofWindow.onClose = { [weak self] w in self?.activeWindows.removeAll { $0 === w } }
        poofWindow.showPoof()
    }
}

// MARK: - Poof Sound (player pool — supports overlapping poofs)

final class PoofSound {
    static let shared = PoofSound()

    /// Pre-built WAV data; rebuilt when volume changes.
    private var wavData: Data?
    private var bundledURL: URL?

    /// Live players. Completed ones remove themselves.
    private var activePlayers: [AVAudioPlayer] = []
    private let playerQueue = DispatchQueue(label: "com.theo.poofonclose.sound")

    init() {
        bundledURL = Bundle.main.url(forResource: "poof", withExtension: "aiff")
        if bundledURL == nil { wavData = buildWAV() }
    }

    func rebuildWAV() {
        if bundledURL == nil { wavData = buildWAV() }
    }

    /// Must be called on the main thread.
    func play() {
        // Build the player on a background queue (WAV synthesis can be slow),
        // then hand it back to main for playback and array management.
        let vol = Preferences.volume
        let bundled = bundledURL
        let wav = wavData
        playerQueue.async { [weak self] in
            guard let self else { return }
            let player: AVAudioPlayer?
            if let url = bundled {
                player = try? AVAudioPlayer(contentsOf: url)
            } else if let data = wav {
                player = try? AVAudioPlayer(data: data)
            } else {
                player = nil
            }
            guard let p = player else { return }
            p.volume = vol
            p.prepareToPlay()
            // All array access on main — no concurrent mutation
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.activePlayers.removeAll { !$0.isPlaying }  // prune stale before adding
                self.activePlayers.append(p)
                p.play()
            }
        }
    }

    private func buildWAV() -> Data {
        let sampleRate: Double = 44100
        let duration:   Double = 0.22
        let numSamples = Int(sampleRate * duration)
        var audioData = [Float](repeating: 0, count: numSamples)

        var lpState: Float = 0
        for i in 0..<numSamples {
            let t = Double(i) / sampleRate
            let cutoff = Float(0.6 * exp(-t * 12) + 0.05)
            let noise   = Float.random(in: -1...1)
            lpState = lpState * (1 - cutoff) + noise * cutoff
            let env = Float(exp(-t * 18) * (1 - exp(-t * 200)))
            audioData[i] = lpState * env * 0.55
        }

        let bytesPerSample = 2
        let dataSize = numSamples * bytesPerSample
        var wav = Data()
        func appendLE<T: FixedWidthInteger>(_ v: T) {
            wav.append(contentsOf: withUnsafeBytes(of: v.littleEndian) { Array($0) })
        }
        wav.append(contentsOf: "RIFF".utf8); appendLE(UInt32(36 + dataSize))
        wav.append(contentsOf: "WAVE".utf8)
        wav.append(contentsOf: "fmt ".utf8); appendLE(UInt32(16))
        appendLE(UInt16(1)); appendLE(UInt16(1))     // PCM, mono
        appendLE(UInt32(44100)); appendLE(UInt32(88200))
        appendLE(UInt16(2)); appendLE(UInt16(16))
        wav.append(contentsOf: "data".utf8); appendLE(UInt32(dataSize))
        for s in audioData {
            appendLE(Int16(max(-32768, min(32767, Int32(s * 32767)))))
        }
        return wav
    }
}

// MARK: - Poof Window

final class PoofWindow: NSWindow {
    private var emitterLayer: CAEmitterLayer?
    private var effectLayers: [CALayer] = []   // tracks ALL added sublayers for clean teardown
    private var puffImage: CGImage?
    private var smallPuffImage: CGImage?
    var onClose: ((PoofWindow) -> Void)?
    private let theme: Preferences.Theme
    private let size: CGFloat

    init(contentRect: CGRect, theme: Preferences.Theme) {
        self.theme = theme
        self.size  = contentRect.width
        super.init(contentRect: contentRect, styleMask: .borderless, backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        level = .screenSaver
        ignoresMouseEvents = true
        hasShadow = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        alphaValue = 0

        let view = NSView(frame: NSRect(origin: .zero, size: contentRect.size))
        view.wantsLayer = true
        view.layer?.backgroundColor = CGColor.clear
        view.layer?.isOpaque = false
        contentView = view

        puffImage      = createPuffImage(size: 32)
        smallPuffImage = createPuffImage(size: 16)
    }

    func showPoof() {
        switch theme {
        case .cloud:   showCloud()
        case .pow:     showPOW()
        case .sparkle: showSparkle()
        case .ripple:  showRipple()
        }
        PoofSound.shared.play()
        scheduleClose()
    }

    // MARK: Themes

    private func showCloud() {
        guard let layer = contentView?.layer,
              let puff = puffImage, let small = smallPuffImage else { return }
        let centre = CGPoint(x: frame.width / 2, y: frame.height / 2)

        let cloud = CALayer()
        cloud.contents = createCartoonCloudImage()
        let cs = size * 0.6
        cloud.bounds   = CGRect(x: 0, y: 0, width: cs, height: cs * 0.83)
        cloud.position = centre
        cloud.opacity  = 0
        addEffect(cloud, to: layer)

        let emitter = makeEmitter(centre: centre, cells: [
            makeCell(image: puff,  birth: 25, vel: 160, scale: 1.4, alphaSpeed: -2.5,
                     color: NSColor(white: 0.95, alpha: 0.9).cgColor),
            makeCell(image: small, birth: 40, vel: 180, scale: 0.8, alphaSpeed: -3.5,
                     color: NSColor(white: 0.88, alpha: 0.75).cgColor)
        ])
        addEffect(emitter, to: layer)

        orderFrontRegardless()
        fadeInWindow()

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values   = [0.0, 1.3, 1.0, 1.1, 0.9]
        pop.keyTimes = [0, 0.2, 0.4, 0.6, 1.0]
        pop.duration = 0.25

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values   = [0, 1.0, 1.0, 0.8, 0]
        fade.keyTimes = [0, 0.1, 0.3, 0.6, 1.0]
        fade.duration = 0.5

        cloud.add(pop,  forKey: "pop")
        cloud.add(fade, forKey: "fade")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { emitter.birthRate = 0 }
    }

    private func showPOW() {
        guard let layer = contentView?.layer, let puff = puffImage else { return }
        let centre = CGPoint(x: frame.width / 2, y: frame.height / 2)

        let burst = CALayer()
        burst.contents = createPOWImage()
        let bs = size * 0.75
        burst.bounds   = CGRect(x: 0, y: 0, width: bs, height: bs)
        burst.position = centre
        burst.opacity  = 0
        addEffect(burst, to: layer)

        let emitter = makeEmitter(centre: centre, cells: [
            makeCell(image: puff, birth: 30, vel: 220, scale: 1.0, alphaSpeed: -4.0,
                     color: NSColor(red: 1.0, green: 0.85, blue: 0.2, alpha: 0.95).cgColor),
            makeCell(image: puff, birth: 20, vel: 180, scale: 0.6, alphaSpeed: -5.0,
                     color: NSColor(red: 1.0, green: 0.4, blue: 0.1, alpha: 0.85).cgColor)
        ])
        addEffect(emitter, to: layer)

        orderFrontRegardless()
        fadeInWindow()

        let pop = CAKeyframeAnimation(keyPath: "transform.scale")
        pop.values   = [0.0, 1.5, 0.85, 1.05, 0.95]
        pop.keyTimes = [0, 0.15, 0.35, 0.55, 1.0]
        pop.duration = 0.2

        let spin = CABasicAnimation(keyPath: "transform.rotation.z")
        spin.fromValue = -0.15; spin.toValue = 0.15; spin.duration = 0.2

        let fade = CAKeyframeAnimation(keyPath: "opacity")
        fade.values   = [0, 1.0, 1.0, 0]
        fade.keyTimes = [0, 0.05, 0.4, 1.0]
        fade.duration = 0.5

        burst.add(pop,  forKey: "pop")
        burst.add(spin, forKey: "spin")
        burst.add(fade, forKey: "fade")

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { emitter.birthRate = 0 }
    }

    private func showSparkle() {
        guard let layer = contentView?.layer else { return }
        let centre = CGPoint(x: frame.width / 2, y: frame.height / 2)
        let star = createStarImage(size: 20)

        let emitter = makeEmitter(centre: centre, cells: [
            makeCell(image: star, birth: 60, vel: 140, scale: 1.2, alphaSpeed: -3.0,
                     color: NSColor(red: 1.0, green: 0.95, blue: 0.4, alpha: 1.0).cgColor),
            makeCell(image: star, birth: 40, vel: 100, scale: 0.6, alphaSpeed: -4.5,
                     color: NSColor(red: 0.7, green: 0.9, blue: 1.0, alpha: 0.9).cgColor),
            makeCell(image: star, birth: 20, vel: 60,  scale: 0.4, alphaSpeed: -6.0,
                     color: NSColor(red: 1.0, green: 0.5, blue: 0.8, alpha: 0.8).cgColor)
        ])
        addEffect(emitter, to: layer)

        orderFrontRegardless()
        fadeInWindow()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { emitter.birthRate = 0 }
    }

    private func showRipple() {
        guard let layer = contentView?.layer else { return }
        let centre = CGPoint(x: frame.width / 2, y: frame.height / 2)

        for i in 0..<3 {
            let ring = CAShapeLayer()
            let r: CGFloat = 20
            ring.path        = NSBezierPath(ovalIn: CGRect(x: -r, y: -r, width: r*2, height: r*2)).cgPath
            ring.position    = centre
            ring.fillColor   = nil
            ring.strokeColor = NSColor(red: 0.4, green: 0.8, blue: 1.0, alpha: 0.8).cgColor
            ring.lineWidth   = 3
            ring.opacity     = 0
            addEffect(ring, to: layer)

            let delay = Double(i) * 0.08

            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue      = 0.1
            scale.toValue        = 3.5
            scale.beginTime      = CACurrentMediaTime() + delay
            scale.duration       = 0.55
            scale.timingFunction = CAMediaTimingFunction(name: .easeOut)

            let fade = CAKeyframeAnimation(keyPath: "opacity")
            fade.values    = [0, 0.9, 0.6, 0]
            fade.keyTimes  = [0, 0.05, 0.4, 1.0]
            fade.beginTime = CACurrentMediaTime() + delay
            fade.duration  = 0.55

            ring.add(scale, forKey: "scale")
            ring.add(fade,  forKey: "fade")
        }

        orderFrontRegardless()
        fadeInWindow()
    }

    // MARK: Layer management

    private func addEffect(_ layer: CALayer, to parent: CALayer) {
        parent.addSublayer(layer)
        effectLayers.append(layer)
        if let emitter = layer as? CAEmitterLayer { self.emitterLayer = emitter }
    }

    private func cleanupAllLayers() {
        effectLayers.forEach { $0.removeFromSuperlayer() }
        effectLayers.removeAll()
        emitterLayer = nil
    }

    // MARK: Animation helpers

    private func makeEmitter(centre: CGPoint, cells: [CAEmitterCell]) -> CAEmitterLayer {
        let e = CAEmitterLayer()
        e.emitterPosition = centre
        e.emitterSize     = CGSize(width: 20, height: 20)
        e.emitterShape    = .circle
        e.renderMode      = .oldestLast
        e.beginTime       = CACurrentMediaTime()
        e.emitterCells    = cells
        return e
    }

    private func makeCell(image: CGImage?, birth: Float, vel: CGFloat, scale: CGFloat,
                          alphaSpeed: Float, color: CGColor) -> CAEmitterCell {
        let c = CAEmitterCell()
        c.contents      = image
        c.birthRate     = birth
        c.lifetime      = 0.4
        c.lifetimeRange = 0.1
        c.velocity      = vel
        c.velocityRange = vel * 0.3
        c.emissionRange = .pi * 2
        c.scale         = scale
        c.scaleRange    = scale * 0.25
        c.scaleSpeed    = alphaSpeed > -3 ? 0.2 : -0.2
        c.alphaSpeed    = alphaSpeed
        c.spin          = 0.5
        c.spinRange     = 1.2
        c.color         = color
        return c
    }

    private func fadeInWindow() {
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = 0.02
            self.animator().alphaValue = 1.0
        }
    }

    private func scheduleClose() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.55) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.15
                self.animator().alphaValue = 0
            }, completionHandler: {
                self.cleanupAllLayers()
                self.orderOut(nil)
                self.onClose?(self)
            })
        }
    }

    // MARK: Image factories

    private func createPuffImage(size: CGFloat) -> CGImage? {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let c = NSPoint(x: size/2, y: size/2)
            let r = size/2 - 2
            let g = NSGradient(
                colorsAndLocations:
                    (NSColor(white: 1.0, alpha: 1.0), 0.0),
                    (NSColor(white: 0.98, alpha: 0.9), 0.3),
                    (NSColor(white: 0.95, alpha: 0.6), 0.6),
                    (NSColor(white: 0.9,  alpha: 0.0), 1.0)
            )
            g?.draw(fromCenter: c, radius: 0, toCenter: c, radius: r, options: [])
            return true
        }
        var rect = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func createCartoonCloudImage() -> CGImage? {
        let cs = size * 0.6; let csh = cs * 0.83
        let img = NSImage(size: NSSize(width: cs, height: csh), flipped: false) { _ in
            let path = NSBezierPath()
            let sx = cs / 120, sy = csh / 100
            for (x, y, r) in [(35,50,28),(60,65,32),(85,50,26),(50,35,24),(75,38,22),(60,45,30)] as [(CGFloat,CGFloat,CGFloat)] {
                path.append(NSBezierPath(ovalIn: NSRect(x:(x-r)*sx, y:(y-r)*sy, width:r*2*sx, height:r*2*sy)))
            }
            NSColor(calibratedRed: 0.98, green: 0.96, blue: 0.92, alpha: 0.95).setFill(); path.fill()
            NSColor(white: 0.7, alpha: 0.4).setStroke(); path.lineWidth = 1.5; path.stroke()
            return true
        }
        var rect = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func createPOWImage() -> CGImage? {
        let s = size * 0.75
        let img = NSImage(size: NSSize(width: s, height: s), flipped: false) { _ in
            let cx = s/2, cy = s/2
            let outer = s * 0.48, inner = s * 0.28
            let spikes = 12
            let path = NSBezierPath()
            for i in 0..<(spikes * 2) {
                let angle = (Double(i) / Double(spikes * 2)) * .pi * 2 - .pi / 2
                let r: CGFloat = i.isMultiple(of: 2) ? outer : inner
                let pt = NSPoint(x: cx + r * CGFloat(cos(angle)), y: cy + r * CGFloat(sin(angle)))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.close()
            NSColor(red: 1.0, green: 0.85, blue: 0.1, alpha: 1.0).setFill(); path.fill()
            NSColor(red: 0.9, green: 0.4,  blue: 0.0, alpha: 0.9).setStroke()
            path.lineWidth = 2.5; path.stroke()
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.boldSystemFont(ofSize: s * 0.22),
                .foregroundColor: NSColor(red: 0.7, green: 0.1, blue: 0.0, alpha: 1.0)
            ]
            let str = NSAttributedString(string: "POW!", attributes: attrs)
            let sz = str.size()
            str.draw(at: NSPoint(x: cx - sz.width/2, y: cy - sz.height/2))
            return true
        }
        var rect = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }

    private func createStarImage(size: CGFloat) -> CGImage? {
        let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { _ in
            let cx = size/2, cy = size/2
            let outer = size/2 - 1, inner = size/4
            let path = NSBezierPath()
            for i in 0..<10 {
                let angle = (Double(i) / 10.0) * .pi * 2 - .pi / 2
                let r: CGFloat = i.isMultiple(of: 2) ? outer : inner
                let pt = NSPoint(x: cx + r * CGFloat(cos(angle)), y: cy + r * CGFloat(sin(angle)))
                if i == 0 { path.move(to: pt) } else { path.line(to: pt) }
            }
            path.close()
            NSColor.white.setFill(); path.fill()
            return true
        }
        var rect = NSRect(origin: .zero, size: img.size)
        return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
    }
}

// MARK: - NSBezierPath → CGPath

extension NSBezierPath {
    var cgPath: CGPath {
        let path = CGMutablePath()
        var pts = [CGPoint](repeating: .zero, count: 3)
        for i in 0..<elementCount {
            switch element(at: i, associatedPoints: &pts) {
            case .moveTo:    path.move(to: pts[0])
            case .lineTo:    path.addLine(to: pts[0])
            case .curveTo:   path.addCurve(to: pts[2], control1: pts[0], control2: pts[1])
            case .closePath: path.closeSubpath()
            @unknown default: break
            }
        }
        return path
    }
}

// MARK: - Volume Slider Menu Item

final class VolumeSliderView: NSView {
    private let slider     = NSSlider()
    private let label      = NSTextField(labelWithString: "Volume")
    private let valueLabel = NSTextField(labelWithString: "")

    override var intrinsicContentSize: NSSize { NSSize(width: 200, height: 36) }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 220, height: 36))

        label.font       = .systemFont(ofSize: 12)
        label.textColor  = .labelColor
        label.frame      = NSRect(x: 12, y: 10, width: 52, height: 18)
        addSubview(label)

        slider.minValue    = 0
        slider.maxValue    = 1
        slider.doubleValue = Double(Preferences.volume)
        slider.frame       = NSRect(x: 68, y: 8, width: 110, height: 20)
        slider.target      = self
        slider.action      = #selector(sliderChanged)
        addSubview(slider)

        valueLabel.font      = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        valueLabel.textColor = .secondaryLabelColor
        valueLabel.frame     = NSRect(x: 182, y: 10, width: 34, height: 18)
        addSubview(valueLabel)
        updateValueLabel()
    }

    required init?(coder: NSCoder) { fatalError() }

    @objc private func sliderChanged() {
        Preferences.volume = Float(slider.doubleValue)
        PoofSound.shared.rebuildWAV()
        updateValueLabel()
    }

    private func updateValueLabel() {
        valueLabel.stringValue = "\(Int(slider.doubleValue * 100))%"
    }
}

// MARK: - App Manager Window

final class AppManagerWindowController: NSWindowController,
                                        NSTableViewDataSource, NSTableViewDelegate {
    private let tableView  = NSTableView()
    private let scrollView = NSScrollView()
    private var apps: [String] = []
    private var currentSegment = 0

    convenience init() {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 380, height: 420),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: true
        )
        win.title = "Manage Apps — Poof on Close"
        win.center()
        self.init(window: win)
        setupUI()
    }

    private func setupUI() {
        guard let cv = window?.contentView else { return }

        let info = NSTextField(wrappingLabelWithString:
            "Apps in the Skip List will not trigger a poof. Add apps to the Allow List to override built-in exclusions.")
        info.frame     = NSRect(x: 12, y: 356, width: 356, height: 52)
        info.font      = .systemFont(ofSize: 12)
        info.textColor = .secondaryLabelColor
        cv.addSubview(info)

        let seg = NSSegmentedControl(labels: ["Skip List", "Allow List"],
                                     trackingMode: .selectOne, target: self,
                                     action: #selector(segChanged(_:)))
        seg.frame            = NSRect(x: 12, y: 318, width: 200, height: 24)
        seg.selectedSegment  = 0
        cv.addSubview(seg)

        scrollView.frame               = NSRect(x: 12, y: 60, width: 356, height: 248)
        scrollView.hasVerticalScroller = true
        scrollView.borderType          = .bezelBorder
        cv.addSubview(scrollView)

        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        col.title = "App Name"; col.width = 340
        tableView.addTableColumn(col)
        tableView.headerView  = nil
        tableView.dataSource  = self
        tableView.delegate    = self
        scrollView.documentView = tableView

        let addBtn = NSButton(title: "+ Add",    target: self, action: #selector(addApp))
        addBtn.frame = NSRect(x: 12, y: 18, width: 90, height: 30)
        cv.addSubview(addBtn)

        let remBtn = NSButton(title: "− Remove", target: self, action: #selector(removeApp))
        remBtn.frame = NSRect(x: 110, y: 18, width: 90, height: 30)
        cv.addSubview(remBtn)

        reloadApps()
    }

    @objc private func segChanged(_ seg: NSSegmentedControl) {
        currentSegment = seg.selectedSegment
        reloadApps()
    }

    private func reloadApps() {
        apps = Array(currentSegment == 0
            ? Preferences.customSkipApps
            : Preferences.allowedApps).sorted()
        tableView.reloadData()
    }

    @objc private func addApp() {
        let alert = NSAlert()
        alert.messageText     = "Add App Name"
        alert.informativeText = "Enter the app's name exactly as shown in Activity Monitor (e.g. Safari, Xcode)."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        alert.window.makeFirstResponder(field)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let name = field.stringValue.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if currentSegment == 0 {
            var s = Preferences.customSkipApps;  s.insert(name); Preferences.customSkipApps = s
        } else {
            var s = Preferences.allowedApps; s.insert(name); Preferences.allowedApps = s
        }
        reloadApps()
    }

    @objc private func removeApp() {
        let row = tableView.selectedRow
        guard row >= 0 && row < apps.count else { return }
        let name = apps[row]
        if currentSegment == 0 {
            var s = Preferences.customSkipApps;  s.remove(name); Preferences.customSkipApps = s
        } else {
            var s = Preferences.allowedApps; s.remove(name); Preferences.allowedApps = s
        }
        reloadApps()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { apps.count }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let cell = NSTextField(labelWithString: apps[row])
        cell.font = .systemFont(ofSize: 13)
        return cell
    }
}

// MARK: - App Delegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem!
    var appManagerWC: AppManagerWindowController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        setupMenuBar()
        WindowTracker.shared.start()
        print("✅ Poof on Close v2.1 running")
    }

    // MARK: Menu Bar

    private func setupMenuBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let btn = statusItem.button {
            btn.image = NSImage(systemSymbolName: "cloud.fill", accessibilityDescription: "Poof on Close")
        }

        let menu = NSMenu()

        let header = NSMenuItem(title: "Poof on Close v2.1", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        // Theme submenu
        let themeMenu = NSMenu()
        for t in Preferences.Theme.allCases {
            let item = NSMenuItem(title: t.rawValue, action: #selector(setTheme(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = t
            item.state  = Preferences.theme == t ? .on : .off
            themeMenu.addItem(item)
        }
        let themeItem = NSMenuItem(title: "Theme", action: nil, keyEquivalent: "")
        themeItem.submenu = themeMenu
        menu.addItem(themeItem)

        // Position submenu
        let posMenu = NSMenu()
        for p in Preferences.PositionMode.allCases {
            let item = NSMenuItem(title: p.rawValue, action: #selector(setPosition(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = p
            item.state  = Preferences.positionMode == p ? .on : .off
            posMenu.addItem(item)
        }
        let posItem = NSMenuItem(title: "Poof Position", action: nil, keyEquivalent: "")
        posItem.submenu = posMenu
        menu.addItem(posItem)

        menu.addItem(.separator())

        // Volume
        let volLabel = NSMenuItem(title: "Volume", action: nil, keyEquivalent: "")
        volLabel.isEnabled = false
        menu.addItem(volLabel)
        let sliderItem = NSMenuItem()
        sliderItem.view = VolumeSliderView()
        menu.addItem(sliderItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Manage Apps…", action: #selector(openAppManager), keyEquivalent: ""))
        menu.addItem(.separator())

        // Launch at Login (macOS 13+ only — requires signed install)
        if #available(macOS 13.0, *) {
            let loginItem = NSMenuItem(title: "Launch at Login",
                                       action: #selector(toggleLaunchAtLogin(_:)),
                                       keyEquivalent: "")
            loginItem.target = self
            loginItem.state  = Preferences.launchAtLogin ? .on : .off
            menu.addItem(loginItem)
            menu.addItem(.separator())
        }

        menu.addItem(NSMenuItem(title: "Test Poof", action: #selector(testPoof), keyEquivalent: "t"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))

        statusItem.menu = menu
    }

    @objc private func setTheme(_ item: NSMenuItem) {
        guard let t = item.representedObject as? Preferences.Theme else { return }
        Preferences.theme = t
        item.menu?.items.forEach { $0.state = .off }
        item.state = .on
    }

    @objc private func setPosition(_ item: NSMenuItem) {
        guard let p = item.representedObject as? Preferences.PositionMode else { return }
        Preferences.positionMode = p
        item.menu?.items.forEach { $0.state = .off }
        item.state = .on
    }

    @available(macOS 13.0, *)
    @objc private func toggleLaunchAtLogin(_ item: NSMenuItem) {
        let requested = !Preferences.launchAtLogin
        do {
            // Attempt registration FIRST — only persist on success
            if requested {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            Preferences.launchAtLogin = requested
            item.state = requested ? .on : .off
        } catch {
            // Restore previous state in UI
            item.state = Preferences.launchAtLogin ? .on : .off
            let alert = NSAlert()
            alert.messageText     = "Launch at Login Failed"
            alert.informativeText = """
\(error.localizedDescription)

Note: Launch at Login requires the app to be code-signed and installed in /Applications. \
An ad hoc build via build.sh may not satisfy this requirement.
"""
            alert.alertStyle = .warning
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }

    @objc private func openAppManager() {
        if appManagerWC == nil { appManagerWC = AppManagerWindowController() }
        appManagerWC?.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc func testPoof() {
        // Construct a fake rect in AppKit coordinates (mouse is already in AppKit coords)
        // and use the convenience helper so coordinate spaces stay consistent.
        let centre = NSEvent.mouseLocation
        PoofAnimator.shared.showPoofAt(
            appKitCentre: centre,
            approximateWindowSize: CGSize(width: 600, height: 400)
        )
    }
}

// MARK: - Entry Point

let app      = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
