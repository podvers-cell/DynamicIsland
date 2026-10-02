import SwiftUI
import AppKit
import CoreAudio
import Accelerate
import ServiceManagement

struct Track: Equatable {
    var bundle = "", title = "", artist = "", playing = false
    var art: NSImage?
    var duration = 0.0, elapsed = 0.0, stamp = Date()

    func elapsed(at now: Date) -> Double {
        min(duration, playing ? elapsed + now.timeIntervalSince(stamp) : elapsed)
    }
}

// Now playing for every app (Spotify, Music, browsers...) via mediaremote-adapter.
final class Player: ObservableObject {
    @Published var track: Track?
    private let res = Bundle.main.resourcePath ?? "."
    private var proc: Process?
    private var pending = Data()

    init() { start() }

    private func adapter(_ args: [String]) -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        p.arguments = ["\(res)/mediaremote-adapter.pl", "\(res)/MediaRemoteAdapter.framework"] + args
        return p
    }

    private func start() {
        let p = adapter(["stream", "--no-diff", "--micros", "--debounce=100"])
        let pipe = Pipe()
        p.standardOutput = pipe
        pipe.fileHandleForReading.readabilityHandler = { [weak self] h in self?.consume(h.availableData) }
        p.terminationHandler = { [weak self] _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { self?.start() }
        }
        try? p.run()
        proc = p
    }

    private func consume(_ data: Data) {
        pending.append(data)
        while let nl = pending.firstIndex(of: 0x0A) {
            let line = pending[pending.startIndex..<nl]
            pending = Data(pending[(nl + 1)...])
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let p = obj["payload"] as? [String: Any] else { continue }
            let t = Self.parse(p)
            DispatchQueue.main.async { self.track = t }
        }
    }

    static func parse(_ p: [String: Any]) -> Track? {
        guard let title = p["title"] as? String, let bundle = p["bundleIdentifier"] as? String else { return nil }
        var t = Track(bundle: bundle, title: title, artist: p["artist"] as? String ?? "", playing: p["playing"] as? Bool ?? false)
        if let b64 = p["artworkData"] as? String, let d = Data(base64Encoded: b64) { t.art = NSImage(data: d) }
        t.duration = (p["durationMicros"] as? Double ?? 0) / 1e6
        t.elapsed = (p["elapsedTimeMicros"] as? Double ?? 0) / 1e6
        if let ts = p["timestampEpochMicros"] as? Double { t.stamp = Date(timeIntervalSince1970: ts / 1e6) }
        return t
    }

    // 2 = toggle play/pause, 4 = next, 5 = previous
    func send(_ id: Int) { try? adapter(["send", "\(id)"]).run() }

    func seek(to seconds: Double) {
        try? adapter(["seek", "\(Int(seconds * 1e6))"]).run()
        track?.elapsed = seconds  // move the bar now; the stream confirms shortly
        track?.stamp = Date()
    }
}

// Real audio levels: Core Audio process tap on system output + FFT into bands.
final class Levels: ObservableObject {
    @Published var bands = [Float](repeating: 0, count: 5)
    // Calibration knobs: band edges in Hz, smoothing decay, auto-gain decay.
    private let edges: [Float] = [40, 150, 400, 1000, 3000, 9000]
    private let decay: Float = 0.82, peakDecay: Float = 0.995
    private let n = 1024
    private var sampleRate: Float = 48000
    private var buf = [Float]()
    private var peak = [Float](repeating: 1e-4, count: 5)
    private var smooth = [Float](repeating: 0, count: 5)
    private lazy var window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: n, isHalfWindow: false)
    private lazy var dft = try! vDSP.DiscreteFourierTransform(count: n, direction: .forward, transformType: .complexComplex, ofType: Float.self)
    private let queue = DispatchQueue(label: "levels", qos: .userInteractive)

    init() { start() }

    private func get<T>(_ obj: AudioObjectID, _ sel: AudioObjectPropertySelector, _ value: inout T) {
        var addr = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<T>.size)
        _ = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0) }
    }

    // ponytail: aggregate is bound to the output device at launch; rebuild on device change if switching headphones breaks it
    private func start() {
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.isPrivate = true
        var tap = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateProcessTap(desc, &tap) == noErr else { return }

        var fmt = AudioStreamBasicDescription()
        get(tap, kAudioTapPropertyFormat, &fmt)
        if fmt.mSampleRate > 0 { sampleRate = Float(fmt.mSampleRate) }

        var out = AudioObjectID(kAudioObjectUnknown)
        get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultSystemOutputDevice, &out)
        var uid: Unmanaged<CFString>?
        get(out, kAudioDevicePropertyDeviceUID, &uid)
        let outUID = uid?.takeRetainedValue() as String? ?? ""

        let agg: [String: Any] = [
            kAudioAggregateDeviceNameKey: "DynamicIslandTap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outUID]],
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true, kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        var dev = AudioObjectID(kAudioObjectUnknown)
        guard AudioHardwareCreateAggregateDevice(agg as CFDictionary, &dev) == noErr else { return }

        var procID: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcIDWithBlock(&procID, dev, queue) { [weak self] _, input, _, _, _ in
            guard let self, let first = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input)).first,
                  let data = first.mData else { return }
            let ch = Int(max(first.mNumberChannels, 1))
            let samples = UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float.self), count: Int(first.mDataByteSize) / 4)
            for i in stride(from: 0, to: samples.count, by: ch) { self.buf.append(samples[i]) }
            while self.buf.count >= self.n {
                self.analyze(Array(self.buf.prefix(self.n)))
                self.buf.removeFirst(self.n)
            }
        }
        AudioDeviceStart(dev, procID)
    }

    private func analyze(_ frame: [Float]) {
        let re = vDSP.multiply(frame, window)
        var outRe = [Float](repeating: 0, count: n), outIm = [Float](repeating: 0, count: n)
        dft.transform(inputReal: re, inputImaginary: [Float](repeating: 0, count: n), outputReal: &outRe, outputImaginary: &outIm)
        let binHz = sampleRate / Float(n)
        var next = smooth
        for b in 0..<5 {
            let lo = max(1, Int(edges[b] / binHz)), hi = max(lo + 1, min(n / 2, Int(edges[b + 1] / binHz)))
            var sum: Float = 0
            for i in lo..<hi { sum += sqrt(outRe[i] * outRe[i] + outIm[i] * outIm[i]) }
            let v = sum / Float(hi - lo)
            peak[b] = max(v, peak[b] * peakDecay, 1e-4)
            next[b] = max(v / peak[b], smooth[b] * decay)
        }
        smooth = next
        DispatchQueue.main.async { self.bands = next }
    }
}

struct Bars: View {
    @ObservedObject var levels: Levels
    let playing: Bool
    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<levels.bands.count, id: \.self) { i in
                Capsule().fill(.green).frame(width: 3, height: 3 + 13 * CGFloat(playing ? levels.bands[i] : 0))
            }
        }
        .frame(height: 16)
        .animation(.linear(duration: 0.06), value: levels.bands)
    }
}

struct Artwork: View {
    let track: Track
    let size: CGFloat
    var body: some View {
        Image(nsImage: track.art ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: track.bundle)
            .map { NSWorkspace.shared.icon(forFile: $0.path) } ?? NSImage())
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size / 4))
    }
}

struct Progress: View {
    let track: Track
    let onSeek: (Double) -> Void
    @State private var drag: Double?  // fraction while dragging

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { ctx in
            let e = drag.map { $0 * track.duration } ?? track.elapsed(at: ctx.date)
            HStack(spacing: 8) {
                Text(Self.fmt(e))
                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(.white.opacity(0.2)).frame(height: drag == nil ? 4 : 6)
                        Capsule().fill(.white).frame(width: g.size.width * CGFloat(e / track.duration), height: drag == nil ? 4 : 6)
                    }
                    .frame(maxHeight: .infinity)
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0)
                        .onChanged { drag = min(1, max(0, $0.location.x / g.size.width)) }
                        .onEnded { _ in
                            if let f = drag { onSeek(f * track.duration) }
                            drag = nil
                        })
                }
                .frame(height: 14)
                Text("-" + Self.fmt(track.duration - e))
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.gray)
        }
    }

    static func fmt(_ s: Double) -> String {
        let s = Int(max(0, s))
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// Unlock animation: macOS only says "unlocked", not how (Touch ID or password).
final class Unlock: ObservableObject {
    @Published var show = false
    @Published var opened = false

    init() {
        DistributedNotificationCenter.default().addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
            self?.play()
        }
    }

    func play() {
        opened = false
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { show = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { withAnimation { self.opened = true } }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.8) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { self.show = false }
        }
    }
}

struct Island: View {
    @ObservedObject var player: Player
    @ObservedObject var unlock: Unlock
    let levels: Levels
    let notchW: CGFloat, notchH: CGFloat
    @State private var open = false

    var body: some View {
        VStack(spacing: 0) {
            if unlock.show {
                HStack {
                    Image(systemName: unlock.opened ? "lock.open.fill" : "lock.fill")
                        .contentTransition(.symbolEffect(.replace))
                        .foregroundStyle(unlock.opened ? .green : .white)
                    Spacer()
                }
                .font(.system(size: 14, weight: .semibold))
                .padding(.horizontal, 14)
                .frame(width: notchW + 70, height: notchH)
                .background(Color.black)
                .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10))
            } else if let t = player.track {
                Group { open ? AnyView(expanded(t)) : AnyView(compact(t)) }
                    .background(Color.black)
                    .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: open ? 28 : 10, bottomTrailingRadius: open ? 28 : 10))
                    .onHover { h in withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { open = h } }
                    .contextMenu {
                        let login = SMAppService.mainApp
                        Button(login.status == .enabled ? "✓ Open at Login" : "Open at Login") {
                            try? login.status == .enabled ? login.unregister() : login.register()
                        }
                        Button("Quit") { NSApp.terminate(nil) }
                    }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
    }

    func compact(_ t: Track) -> some View {
        HStack {
            Artwork(track: t, size: 20)
            Spacer()
            Bars(levels: levels, playing: t.playing)
        }
        .padding(.horizontal, 12)
        .frame(width: notchW + 90, height: notchH)
    }

    func expanded(_ t: Track) -> some View {
        VStack(spacing: 12) {
            HStack(spacing: 12) {
                Artwork(track: t, size: 56)
                VStack(alignment: .leading, spacing: 3) {
                    Text(t.title).font(.headline).foregroundStyle(.white).lineLimit(1)
                    Text(t.artist).font(.subheadline).foregroundStyle(.gray).lineLimit(1)
                }
                Spacer()
                Bars(levels: levels, playing: t.playing)
            }
            if t.duration > 0 { Progress(track: t) { player.seek(to: $0) } }
            HStack(spacing: 36) {
                button("backward.fill", 5)
                button(t.playing ? "pause.fill" : "play.fill", 2)
                button("forward.fill", 4)
            }
        }
        .padding(.top, notchH + 4)
        .padding([.horizontal, .bottom], 20)
        .frame(width: max(notchW + 180, 400))
    }

    func button(_ icon: String, _ cmd: Int) -> some View {
        Button { player.send(cmd) } label: { Image(systemName: icon).font(.title2).foregroundStyle(.white) }
            .buttonStyle(.plain)
    }
}

final class Host<V: View>: NSHostingView<V> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var panel: NSPanel!
    let player = Player()
    let levels = Levels()
    let unlock = Unlock()

    func applicationDidFinishLaunching(_ n: Notification) {
        let screen = NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main!
        let notchH = max(screen.safeAreaInsets.top, 24)
        let notchW = screen.frame.width - (screen.auxiliaryTopLeftArea?.width ?? screen.frame.width / 2 - 100)
                                        - (screen.auxiliaryTopRightArea?.width ?? screen.frame.width / 2 - 100)
        let w: CGFloat = 600, h: CGFloat = 240
        panel = NSPanel(contentRect: NSRect(x: screen.frame.midX - w / 2, y: screen.frame.maxY - h, width: w, height: h),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.contentView = Host(rootView: Island(player: player, unlock: unlock, levels: levels, notchW: notchW, notchH: notchH))
        panel.orderFrontRegardless()

        // Open at login on first run only, so turning it off in System Settings sticks.
        if !UserDefaults.standard.bool(forKey: "loginItemSet") {
            try? SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: "loginItemSet")
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
