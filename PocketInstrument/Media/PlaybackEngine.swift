import AVFoundation
import Observation

/// Wraps one AVPlayer for the workspace. It plays either the assembled
/// sequence (Arrange) or one source file (Explore), loops the whole item or a
/// sub-range, and coalesces scrub seeks so dragging stays smooth.
@MainActor
@Observable
final class PlaybackEngine {
    let player = AVPlayer()

    private(set) var currentTime: CMTime = .zero
    private(set) var duration: CMTime = .zero
    private(set) var isPlaying = false
    /// Shuttle speed while the jog dial is pushed out (negative plays backwards), else nil.
    private(set) var shuttleRate: Float?

    /// When set, playback wraps inside this range instead of the whole item.
    var loopRange: CMTimeRange?

    @ObservationIgnored private var timeObserver: Any?
    @ObservationIgnored private var endObserver: NSObjectProtocol?
    @ObservationIgnored private var isSeeking = false
    @ObservationIgnored private var pendingSeek: (time: CMTime, precise: Bool)?
    /// Steps the playhead for shuttle speeds this item can't play natively.
    @ObservationIgnored private var shuttleTask: Task<Void, Never>?

    init() {
        player.actionAtItemEnd = .pause
        let interval = CMTime(value: 1, timescale: 30)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] time in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.tick(time)
            }
        }
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil, queue: .main
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self, (note.object as? AVPlayerItem) === self.player.currentItem else { return }
                self.handleEnd()
            }
        }
    }

    // Note: the engine lives as long as its WorkspaceModel; observers are
    // removed in `tearDown()` which the workspace calls on dismissal.
    func tearDown() {
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        timeObserver = nil
        endObserver = nil
        player.replaceCurrentItem(with: nil)
    }

    // MARK: Loading

    func load(_ item: AVPlayerItem?, duration: CMTime, at time: CMTime, resume: Bool? = nil) {
        let shouldPlay = resume ?? isPlaying
        player.replaceCurrentItem(with: item)
        self.duration = duration
        currentTime = time
        guard item != nil else {
            pause()
            return
        }
        player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, shouldPlay else { return }
                self.play()
            }
        }
    }

    // MARK: Transport

    func play() {
        guard player.currentItem != nil else { return }
        if let loopRange, !loopRange.containsTime(currentTime) {
            seek(to: loopRange.start, precise: true)
        } else if CMTimeCompare(currentTime, duration) >= 0 && duration > .zero {
            seek(to: .zero, precise: true)
        }
        player.play()
        isPlaying = true
    }

    func pause() {
        player.pause()
        isPlaying = false
    }

    func togglePlay() { isPlaying ? pause() : play() }

    // MARK: Shuttle

    /// Plays at `rate` (e.g. 0.25 to 4, negative for reverse) until `endShuttle`, ignoring the loop
    /// and stopping at either end. Speeds the item can't play natively are stepped by seeking.
    func shuttle(rate: Float) {
        guard let item = player.currentItem, rate != 0 else { return }
        if isPlaying { pause() }
        shuttleRate = rate
        let native =
            switch rate {
            case 2...: rate == 2 || item.canPlayFastForward
            case 0...: true
            case -1: item.canPlayReverse
            case -1..<0: item.canPlaySlowReverse
            default: item.canPlayFastReverse
            }
        shuttleTask?.cancel()
        shuttleTask = nil
        if native {
            player.rate = rate
            return
        }
        player.pause()
        shuttleTask = Task { [weak self] in
            let tick = 1.0 / 30
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(tick))
                guard let self, let rate = self.shuttleRate else { return }
                let next = CMTimeAdd(self.currentTime, CMTime(seconds: Double(rate) * tick, preferredTimescale: 600))
                self.seek(to: next, precise: false)
                if next <= .zero || next >= self.duration { return }
            }
        }
    }

    /// Stops shuttling and settles exactly on the frame it stopped at.
    func endShuttle() {
        guard shuttleRate != nil else { return }
        let stopped = shuttleTask == nil ? player.currentTime() : currentTime
        shuttleRate = nil
        shuttleTask?.cancel()
        shuttleTask = nil
        player.pause()
        seek(to: stopped, precise: true)
    }

    /// Coalesced seek: while one seek is in flight, only the latest request is kept.
    func seek(to time: CMTime, precise: Bool) {
        let clamped = CMTimeClampToRange(time, range: CMTimeRange(start: .zero, duration: duration))
        currentTime = clamped
        if isSeeking {
            pendingSeek = (clamped, precise)
            return
        }
        isSeeking = true
        let tolerance = precise ? CMTime.zero : CMTime(value: 1, timescale: 10)
        player.seek(to: clamped, toleranceBefore: tolerance, toleranceAfter: tolerance) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.isSeeking = false
                if let next = self.pendingSeek {
                    self.pendingSeek = nil
                    self.seek(to: next.time, precise: next.precise)
                }
            }
        }
    }

    /// Frame-accurate stepping (pauses playback).
    func step(frames: Int) {
        pause()
        player.currentItem?.step(byCount: frames)
        currentTime = player.currentTime()
    }

    // MARK: Internals

    private func tick(_ time: CMTime) {
        guard !isSeeking else { return }
        currentTime = time
        if isPlaying, let loopRange, CMTimeCompare(time, loopRange.end) >= 0 {
            seek(to: loopRange.start, precise: true)
        }
    }

    private func handleEnd() {
        guard isPlaying else { return }
        // Loop the whole item (or the loop range) per the instrument's always-looping preview.
        seek(to: loopRange?.start ?? .zero, precise: true)
        player.play()
    }
}
