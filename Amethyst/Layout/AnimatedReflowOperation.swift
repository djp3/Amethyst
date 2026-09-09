//
//  AnimatedReflowOperation.swift
//  Amethyst
//
//  Created by Don Patterson on 9/8/26.
//  Copyright © 2026 Ian Ynda-Hummel. All rights reserved.
//

import CoreGraphics
import Foundation
import os.log

/// Unified-log channel for animation timing, readable with `log stream --info --predicate 'subsystem == "com.amethyst.Amethyst"'` even in release builds.
private let animationLog = OSLog(subsystem: "com.amethyst.Amethyst", category: "animation")

/// How long to wait for slow applications to apply their last frame before moving on.
private let writerDrainTimeout: TimeInterval = 1.0

/// How long a proxy takes to correct itself when an application only reports its real size after the glide has ended.
private let lateCorrectionDuration: TimeInterval = 0.1

/// The least time a proxy takes to dissolve into a fresh capture, even when the glide is about to end; shorter reads as a snap.
private let minimumDissolveDuration: TimeInterval = 0.15

/// How long after an application accepts its new frame to wait before capturing it again. The accessibility call returns before many applications have redrawn, and a capture taken too early shows stale or empty content.
private let redrawSettleDelay: TimeInterval = 0.06

/// Pure interpolation helpers for animated reflows.
enum FrameInterpolation {
    /// Sinusoidal ease-in-out: gentle start and finish, with peak velocity only about 1.6x linear so no single frame jumps far even at low tick rates.
    static func easeInOutSine(_ progress: CGFloat) -> CGFloat {
        let clamped = min(max(progress, 0), 1)
        return (1 - cos(clamped * .pi)) / 2
    }

    /**
     Linearly interpolates between two rects.

     Each edge is interpolated and rounded independently, so every edge of the result lies between the corresponding edges of `start` and `end`, and consecutive ticks either produce a visibly different frame or an identical one that can be skipped. Rounding origin and size separately would not give that guarantee.
     */
    static func interpolate(from start: CGRect, to end: CGRect, progress: CGFloat) -> CGRect {
        func lerp(_ startValue: CGFloat, _ endValue: CGFloat) -> CGFloat {
            return (startValue + (endValue - startValue) * progress).rounded()
        }

        let minX = lerp(start.minX, end.minX)
        let minY = lerp(start.minY, end.minY)
        let maxX = lerp(start.maxX, end.maxX)
        let maxY = lerp(start.maxY, end.maxY)

        return CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
    }

    /// Rounds a rect to integral points.
    static func integral(_ rect: CGRect) -> CGRect {
        return interpolate(from: rect, to: rect, progress: 0)
    }

    /**
     A live window frame rounded to integral points, or `nil` if it could not be read.

     An accessibility frame read fails when the application is hung or the window has gone, and Silica reports that as the null rect, whose coordinates are infinite. Doing arithmetic on it yields NaN, which traps when converted to an integer and is rejected by Core Animation, so every read goes through here.
     */
    static func readable(_ rect: CGRect) -> CGRect? {
        guard !rect.isNull, !rect.isInfinite, [rect.minX, rect.minY, rect.width, rect.height].allSatisfy({ $0.isFinite }) else {
            return nil
        }
        return integral(rect)
    }
}

/**
 Applies frame writes for one application on a serial queue of its own.

 Accessibility writes block until the target application has processed them, and applications differ wildly in how quickly they do so. Each writer always applies the newest frame requested for each of its windows and drops any frames it could not keep up with, so a slow application only lowers its own frame rate instead of holding every other window back.
 */
final class ApplicationFrameWriter<Window: WindowType> {
    struct Write {
        let window: Window
        let frame: CGRect
        let includingSize: Bool
    }

    struct Statistics {
        var requested = 0
        var applied = 0
        var totalWriteTime: TimeInterval = 0

        var averageWriteTime: TimeInterval {
            return applied == 0 ? 0 : totalWriteTime / TimeInterval(applied)
        }
    }

    let pid: pid_t

    /// `nil` applies writes inline on the caller's thread, which keeps tests deterministic.
    private let queue: DispatchQueue?
    private let group: DispatchGroup
    private let now: () -> TimeInterval
    private let lock = NSLock()
    private var pending: [Int: Write] = [:]
    private var isDraining = false
    private var statistics = Statistics()

    init(pid: pid_t, group: DispatchGroup, inline: Bool, now: @escaping () -> TimeInterval) {
        self.pid = pid
        self.group = group
        self.now = now
        self.queue = inline ? nil : DispatchQueue(label: "Amethyst.ApplicationFrameWriter.\(pid)", qos: .userInteractive)
    }

    /// Requests writes keyed by window. A later request for the same window supersedes an earlier one that has not been applied yet.
    func write(_ writes: [Int: Write]) {
        lock.lock()
        for (key, write) in writes {
            pending[key] = write
            statistics.requested += 1
        }
        let shouldStartDraining = !isDraining && !pending.isEmpty
        if shouldStartDraining {
            isDraining = true
        }
        lock.unlock()

        guard shouldStartDraining else {
            return
        }

        group.enter()
        if let queue = queue {
            queue.async { self.drain() }
        } else {
            drain()
        }
    }

    /// Whether every requested write has been applied.
    var isIdle: Bool {
        lock.lock()
        defer { lock.unlock() }
        return pending.isEmpty && !isDraining
    }

    /// Drops frames that have not been applied yet, for cancellation.
    func discardPending() {
        lock.lock()
        pending.removeAll()
        lock.unlock()
    }

    func statisticsSnapshot() -> Statistics {
        lock.lock()
        defer { lock.unlock() }
        return statistics
    }

    func resetStatistics() {
        lock.lock()
        statistics = Statistics()
        lock.unlock()
    }

    private func drain() {
        while true {
            lock.lock()
            let batch = pending
            pending.removeAll()
            if batch.isEmpty {
                isDraining = false
                lock.unlock()
                group.leave()
                return
            }
            lock.unlock()

            for write in batch.values {
                let start = now()
                write.window.setAnimationFrame(write.frame, includingSize: write.includingSize)
                let elapsed = now() - start

                lock.lock()
                statistics.applied += 1
                statistics.totalWriteTime += elapsed
                lock.unlock()
            }
        }
    }
}

/**
 Which screen each animating window currently belongs to.

 While a window is being moved and resized behind the backdrop it can briefly have most of its area on another display, and a reflow on that display, triggered for example by an application activating, would otherwise claim it and tile it there. Registering in-flight windows lets the screen filters keep them with the screen that is animating them.
 */
final class AnimatingWindows {
    static let shared = AnimatingWindows()

    private let lock = NSLock()
    private var screenIDsByWindow: [CGWindowID: String] = [:]
    private var lastSeenFrames: [CGWindowID: (frame: CGRect, time: TimeInterval)] = [:]

    /// How long a cancelled animation's last picture positions stay relevant to a follow-up animation.
    static let lastSeenFrameLifetime: TimeInterval = 1.0

    /**
     Remembers where a cancelled animation last showed each window, so the animation that replaces it can start its pictures
     there rather than from the windows' real frames. The real windows are left at valid tiles regardless.
     */
    func recordLastSeenFrames(_ frames: [CGWindowID: CGRect], at time: TimeInterval) {
        lock.lock()
        for (windowID, frame) in frames {
            lastSeenFrames[windowID] = (frame, time)
        }
        lock.unlock()
    }

    /// Where the window's picture was last seen, if a cancelled animation recorded it recently. Consumed on read.
    func takeLastSeenFrame(for windowID: CGWindowID, at time: TimeInterval) -> CGRect? {
        lock.lock()
        defer { lock.unlock() }
        lastSeenFrames = lastSeenFrames.filter { time - $0.value.time <= AnimatingWindows.lastSeenFrameLifetime }
        return lastSeenFrames.removeValue(forKey: windowID)?.frame
    }

    func claim(_ windowIDs: [CGWindowID], for screenID: String) {
        lock.lock()
        for windowID in windowIDs {
            screenIDsByWindow[windowID] = screenID
        }
        lock.unlock()
    }

    /**
     Drops any claim on the windows, whichever screen holds it.

     Called when Amethyst itself relocates a window to another screen or Space: the animation that was moving it must stop touching it, and the destination screen must be free to adopt it at once.
     */
    func handOff(_ windowIDs: [CGWindowID]) {
        lock.lock()
        for windowID in windowIDs {
            screenIDsByWindow[windowID] = nil
        }
        lock.unlock()
    }

    /// Releases windows claimed for `screenID`; claims made since by another screen are left alone.
    func release(_ windowIDs: [CGWindowID], for screenID: String) {
        lock.lock()
        for windowID in windowIDs where screenIDsByWindow[windowID] == screenID {
            screenIDsByWindow[windowID] = nil
        }
        lock.unlock()
    }

    /// The screen animating the window, if any.
    func screenID(for windowID: CGWindowID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return screenIDsByWindow[windowID]
    }

    /// Whether an animation is currently moving the window, so a move or resize notification about it is Amethyst's own doing rather than a user gesture.
    func isAnimating(_ windowID: CGWindowID) -> Bool {
        return screenID(for: windowID) != nil
    }
}

/**
 Applies every frame assignment of a reflow together over a fixed duration.

 Regular reflows enqueue one `FrameAssignmentOperation` per window on a serial queue. Wrapping them all in a single operation lets every window move at the same time, keeps the completion operation's dependency structure intact, and makes cancellation via `cancelAllOperations()` take effect between steps.

 Two strategies are available, chosen per reflow:

 **Snapshot** (preferred, needs Screen Recording permission and the private SkyLight capture): an image of each window is captured and shown in an overlay exactly where the window is; the real window is parked off-screen, given its final size there (the one expensive relayout happens out of sight), and the images slide to their targets with Core Animation. Then the real windows are placed at their targets and the images fade out. The user only ever sees the compositor moving pixels, so the motion is smooth regardless of how slow the applications are.

 **Accessibility** (fallback): windows are resized in place, then their positions glide through repeated Accessibility writes, handed to a writer per application. Moving a window is cheap for the application; resizing is not, which is why the resize happens once up front.

 In both cases the final frame goes through the normal `FrameAssignment.perform(withWindow:)`, so the end state is identical to a non-animated reflow.
 */
final class AnimatedReflowOperation<Window: WindowType>: Operation, @unchecked Sendable {
    private struct Participant {
        let assignment: FrameAssignment<Window>
        let window: Window
        let pid: pid_t
        let start: CGRect
        /// Where the window's picture starts: where a cancelled animation last showed it, if that was a moment ago, else its real frame.
        let visualStart: CGRect
        /// Where the window should end up. Corrected mid-animation if the application refuses the assigned size.
        var target: CGRect
        let resizable: Bool
        var lastIssued: CGRect
        /// Pixels per point of the window's first capture, for validating later captures.
        var pixelsPerPoint: CGFloat = 1

        /// The frame this window should show at `progress` of the accessibility glide: interpolated position, already-final size, kept on screen if focused.
        func frame(at progress: CGFloat) -> CGRect {
            let interpolated = FrameInterpolation.interpolate(from: start, to: target, progress: progress)
            return assignment.keepingFocusedWindowOnScreen(CGRect(origin: interpolated.origin, size: lastIssued.size))
        }
    }

    private typealias Writes = [pid_t: [Int: ApplicationFrameWriter<Window>.Write]]

    private struct SnapshotTimings {
        var inPlace = false
        var captureDuration: TimeInterval = 0
        var parkDuration: TimeInterval = 0
        var placeDuration: TimeInterval = 0
        var corrected = 0
        var recaptured = 0
        /// When, relative to the start of the glide, the first application finished re-laying out and its proxy could be refined.
        var firstRefinement: TimeInterval?
        /// Resized windows whose proxy never received a fresh image; they get a slow dissolve at the handoff instead.
        var unrefreshed: [Int] = []
    }

    private enum SnapshotOutcome {
        case completed(animator: SnapshotAnimating, timings: SnapshotTimings)
        case cancelled
        case unavailable(reason: String)
    }

    /// How long the proxies take to fade once the real windows are back in place.
    private static var handoffFadeDuration: TimeInterval { return 0.08 }

    /// How long a proxy that never received a fresh image takes to dissolve into the real window at the handoff.
    private static var lingeringFadeDuration: TimeInterval { return 0.25 }

    private let frameAssignments: [FrameAssignment<Window>]
    private let windowSet: WindowSet<Window>?
    private let duration: TimeInterval
    private let frameInterval: TimeInterval
    private let writesInline: Bool
    private let captureImages: (([WindowCaptureRequest]) -> [CGImage]?)?
    private let captureBackdrop: ((CGRect, [CGWindowID]) -> CGImage?)?
    private let makeSnapshotAnimator: (() -> SnapshotAnimating)?
    private let parkingOrigin: () -> CGPoint
    private let screenID: String?
    private let now: () -> TimeInterval
    private let sleep: (TimeInterval) -> Void

    private let writerGroup = DispatchGroup()
    private var writers: [pid_t: ApplicationFrameWriter<Window>] = [:]

    /// Participants whose size is being changed by the current snapshot animation; only these need a fresh capture.
    private var resizedIndexSet: Set<Int> = []

    /// Whether the current snapshot animation keeps the real windows on screen behind a backdrop rather than parking them.
    private var refinesInPlace = false

    /// Number of accessibility glide ticks performed. Exposed for tests.
    private(set) var tickCount = 0

    /**
     - Parameters:
         - frameAssignmentOperations: The per-window operations a layout produced. Their assignments are animated together and their shared window set resolves live windows.
         - duration: Total glide time in seconds. Capture and the up-front resize are not counted against it.
         - frameInterval: Target time between accessibility glide ticks, and the pause that lets the overlay draw before windows are parked.
         - writesInline: Apply writes synchronously on the operation's thread instead of on per-application queues. For tests.
         - captureImages: Captures full images of the given windows; `nil` disables the snapshot strategy.
         - captureBackdrop: Captures a screen without the given windows. With it, real windows are re-laid out in place behind the backdrop and their proxies cross-dissolve to fresh captures; without it they are parked off-screen.
         - makeSnapshotAnimator: Creates the overlay that shows and slides the snapshots; `nil` disables the snapshot strategy.
         - parkingOrigin: A point beyond every display where real windows are hidden during a snapshot animation.
         - screenID: The screen this reflow belongs to; its windows are registered as in flight so other screens leave them alone.
         - now: Monotonic clock, injectable for tests.
         - sleep: Blocking sleep, injectable for tests.
     */
    init(
        frameAssignmentOperations: [FrameAssignmentOperation<Window>],
        duration: TimeInterval,
        frameInterval: TimeInterval = 1.0 / 60.0,
        writesInline: Bool = false,
        captureImages: (([WindowCaptureRequest]) -> [CGImage]?)? = nil,
        captureBackdrop: ((CGRect, [CGWindowID]) -> CGImage?)? = nil,
        makeSnapshotAnimator: (() -> SnapshotAnimating)? = nil,
        parkingOrigin: @escaping () -> CGPoint = AnimatedReflowOperation.defaultParkingOrigin,
        screenID: String? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) {
        self.frameAssignments = frameAssignmentOperations.map { $0.frameAssignment }
        self.windowSet = frameAssignmentOperations.first?.windowSet
        self.duration = duration
        self.frameInterval = frameInterval
        self.writesInline = writesInline
        self.captureImages = captureImages
        self.captureBackdrop = captureBackdrop
        self.makeSnapshotAnimator = makeSnapshotAnimator
        self.parkingOrigin = parkingOrigin
        self.screenID = screenID
        self.now = now
        self.sleep = sleep
        super.init()
    }

    // MARK: - Parking

    /// A point to the right of every active display, in the flipped coordinates Accessibility uses.
    static func defaultParkingOrigin() -> CGPoint {
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        var displays = [CGDirectDisplayID](repeating: 0, count: Int(displayCount))
        CGGetActiveDisplayList(displayCount, &displays, &displayCount)
        return parkingOrigin(forDisplayBounds: displays.map { CGDisplayBounds($0) })
    }

    static func parkingOrigin(forDisplayBounds bounds: [CGRect]) -> CGPoint {
        let union = bounds.reduce(CGRect.null) { $0.union($1) }
        return CGPoint(x: (union.isNull ? 0 : union.maxX) + 200, y: 0)
    }

    // MARK: - Operation

    override func main() {
        guard !isCancelled, let windowSet = windowSet else {
            return
        }

        var participants = prepareParticipants(in: windowSet)
        let windowIDs = participants.map { $0.window.cgID() }
        if let screenID = screenID {
            AnimatingWindows.shared.claim(windowIDs, for: screenID)
        }

        var snapshotAnimator: SnapshotAnimating?
        var lingeringProxies: [Int] = []
        var overlayHandedOff = false

        defer {
            // Whatever path leads out of here, the overlay must not outlive the operation: a cancellation that arrives after the
            // glide would otherwise leave the panel, backdrop and all, on screen until the app is relaunched. By then the real
            // windows are already in place, so taking it down at once is invisible; only the normal path gets the fade.
            if let animator = snapshotAnimator, !overlayHandedOff {
                runOnMainSync { animator.cancel() }
            }
            if let screenID = screenID {
                AnimatingWindows.shared.release(windowIDs, for: screenID)
            }
            participants.forEach { $0.window.endAnimatedMovement() }
        }

        if !participants.isEmpty {
            switch attemptSnapshotAnimation(&participants) {
            case let .completed(animator, timings):
                snapshotAnimator = animator
                lingeringProxies = timings.unrefreshed
                logSnapshotTiming(windowCount: participants.count, timings: timings)
            case .cancelled:
                return
            case let .unavailable(reason):
                log.debug("Animated reflow: snapshot animation unavailable (\(reason)); moving the real windows instead")
                os_log("Animated reflow: snapshot animation unavailable (%{public}s); moving the real windows instead", log: animationLog, type: .info, reason)

                let resizeStart = now()
                resizeInPlace(&participants)
                let resizeDuration = now() - resizeStart

                guard !isCancelled, animate(&participants, resizeDuration: resizeDuration) else {
                    return
                }
            }
        }

        guard !isCancelled else {
            return
        }

        // Settle: apply the exact final frames through the regular path, including focused-window peeking, except for windows
        // Amethyst has since moved elsewhere.
        for frameAssignment in frameAssignments where windowSet.window(for: frameAssignment).map(owns) ?? false {
            windowSet.perform(frameAssignment: frameAssignment)
        }

        // Only now hand the picture back to the real windows.
        if let animator = snapshotAnimator {
            runOnMainSync {
                animator.finish(
                    fadeDuration: AnimatedReflowOperation.handoffFadeDuration,
                    lingering: lingeringProxies,
                    lingerDuration: AnimatedReflowOperation.lingeringFadeDuration
                ) {}
            }
            overlayHandedOff = true
            logFinalFrameMismatches(participants)
        }
    }

    /// Reports any window whose settled frame differs from where its proxy landed; a non-empty list means the handoff shows a jump.
    private func logFinalFrameMismatches(_ participants: [Participant]) {
        let mismatches = participants.compactMap { participant -> String? in
            guard let actual = FrameInterpolation.readable(participant.window.frame()), actual != participant.target else {
                return nil
            }
            return "pid \(participant.pid) proxy \(Int(participant.target.minX)),\(Int(participant.target.minY)) \(Int(participant.target.width))x\(Int(participant.target.height))"
                + " window \(Int(actual.minX)),\(Int(actual.minY)) \(Int(actual.width))x\(Int(actual.height))"
        }

        guard !mismatches.isEmpty else {
            return
        }

        log.debug("Animated reflow: proxy/window mismatch after settle: \(mismatches.joined(separator: "; "))")
        os_log("Animated reflow: proxy/window mismatch after settle: %{public}s", log: animationLog, type: .info, mismatches.joined(separator: "; "))
    }

    /// Resolves live windows and captures start frames in a single main-thread hop.
    private func prepareParticipants(in windowSet: WindowSet<Window>) -> [Participant] {
        var participants: [Participant] = []

        runOnMainSync {
            guard !isCancelled else {
                return
            }

            for assignment in frameAssignments {
                guard let window = windowSet.window(for: assignment) else {
                    continue
                }

                // A window whose frame cannot be read is left to the settle pass, exactly as a non-animated reflow treats it.
                guard let start = FrameInterpolation.readable(window.frame()), let target = FrameInterpolation.readable(assignment.finalFrame) else {
                    continue
                }

                guard start != target else {
                    continue
                }

                window.beginAnimatedMovement()
                participants.append(Participant(
                    assignment: assignment,
                    window: window,
                    pid: window.pid(),
                    start: start,
                    visualStart: AnimatingWindows.shared.takeLastSeenFrame(for: window.cgID(), at: now()) ?? start,
                    target: target,
                    resizable: window.isResizable(),
                    lastIssued: start
                ))
            }
        }

        return participants
    }

    // MARK: - Snapshot strategy

    private func attemptSnapshotAnimation(_ participants: inout [Participant]) -> SnapshotOutcome {
        guard let captureImages = captureImages, let makeSnapshotAnimator = makeSnapshotAnimator else {
            return .unavailable(reason: "disabled")
        }

        let windowIDs = participants.map { $0.window.cgID() }
        let requests = participants.map { WindowCaptureRequest(windowID: $0.window.cgID(), frame: $0.start) }
        let screenFrame = participants[0].assignment.screenFrame
        var timings = SnapshotTimings()

        // Window images and the backdrop are independent round trips; take them at the same time.
        let captureStart = now()
        var images: [CGImage]?
        var backdrop: CGImage?
        let captureBackdrop = self.captureBackdrop
        DispatchQueue.concurrentPerform(iterations: captureBackdrop == nil ? 1 : 2) { task in
            if task == 0 {
                images = captureImages(requests)
            } else {
                backdrop = captureBackdrop?(screenFrame, windowIDs)
            }
        }
        timings.captureDuration = now() - captureStart

        guard let images = images, images.count == participants.count else {
            return .unavailable(reason: "window capture failed")
        }
        timings.inPlace = backdrop != nil

        for (index, image) in images.enumerated() where participants[index].start.width > 0 {
            participants[index].pixelsPerPoint = CGFloat(image.width) / participants[index].start.width
        }

        let proxies = zip(participants, images).map { participant, image in
            SnapshotProxy(image: image, start: participant.visualStart, target: participant.target)
        }

        var animator: SnapshotAnimating?
        runOnMainSync {
            let created = makeSnapshotAnimator()
            created.show(proxies: proxies, screenFrame: screenFrame, backdrop: backdrop)
            animator = created
        }

        guard let animator = animator else {
            return .unavailable(reason: "overlay unavailable")
        }

        // Give the compositor one frame to draw the overlay over the real windows before those move.
        sleep(frameInterval)

        let resizedIndices = hideRealWindows(&participants, inPlace: timings.inPlace, timings: &timings)
        resizedIndexSet = Set(resizedIndices)
        refinesInPlace = timings.inPlace

        guard !isCancelled else {
            return abandonSnapshotAnimation(animator, &participants)
        }

        let finished = DispatchSemaphore(value: 0)
        runOnMainSync {
            animator.animate(duration: duration) {
                finished.signal()
            }
        }

        guard glide(&participants, animator: animator, finished: finished, timings: &timings) else {
            return abandonSnapshotAnimation(animator, &participants)
        }

        timings.placeDuration = placeRealWindows(&participants)
        return .completed(animator: animator, timings: timings)
    }

    /**
     Waits for the proxies' motion to end while refining them, checking for cancellation every frame and never waiting forever.

     As each application applies its new frame, its proxies are steered to the frame it accepted. Behind a backdrop the resized
     windows are then captured again, once they have had time to redraw, and their proxies dissolve into the fresh image. A
     capture whose surface does not yet match the accepted size is retried, since many applications redraw well after the
     accessibility call returns.

     - Returns: `false` if the operation was cancelled.
     */
    private func glide(_ participants: inout [Participant], animator: SnapshotAnimating, finished: DispatchSemaphore, timings: inout SnapshotTimings) -> Bool {
        let glideStart = now()
        var pendingSteer = refinesInPlace ? Set(participants.indices) : resizedIndexSet
        var pendingRecapture: [Int: TimeInterval] = [:]
        var retiredProxies = Set<Int>()
        var refinements: [DispatchGroup] = []
        var remainingWaits = Int(((duration + 1.0) / frameInterval).rounded(.up))

        while finished.wait(timeout: .now()) == .timedOut {
            // Pace the checks with the injectable sleep so the injected clock advances in tests.
            sleep(frameInterval)
            remainingWaits -= 1
            if isCancelled || remainingWaits <= 0 {
                return false
            }

            // A window thrown to another screen or Space mid-glide is no longer ours: stop refining it and hide its proxy.
            let retired = retireHandedOffProxies(participants, alreadyRetired: &retiredProxies, animator: animator)
            pendingSteer.subtract(retired)
            for index in retired {
                pendingRecapture[index] = nil
            }

            let current = now()
            let elapsed = current - glideStart

            let steerable = pendingSteer.filter { writer(for: participants[$0].pid).isIdle }
            if !steerable.isEmpty {
                pendingSteer.subtract(steerable)
                if timings.firstRefinement == nil {
                    timings.firstRefinement = elapsed
                }
                timings.corrected += steerToAcceptedFrames(animator, &participants, indices: steerable.sorted(), duration: max(duration - elapsed, 0.05), completion: nil)
                for index in steerable where refinesInPlace && resizedIndexSet.contains(index) {
                    pendingRecapture[index] = current + redrawSettleDelay
                }
            }

            let due = pendingRecapture.filter { $0.value <= current }.map { $0.key }
            if !due.isEmpty {
                let (group, dissolved) = dissolveToFreshCaptures(animator, participants, indices: due.sorted(), duration: max(duration - elapsed, minimumDissolveDuration), isFinalAttempt: false)
                refinements.append(contentsOf: [group].compactMap { $0 })
                timings.recaptured += dissolved.count
                for index in due {
                    pendingRecapture[index] = dissolved.contains(index) ? nil : current + redrawSettleDelay
                }
            }
        }

        refinements += finishRefinement(&participants, animator: animator, pendingSteer: pendingSteer, pendingRecapture: Set(pendingRecapture.keys), timings: &timings)

        for refinement in refinements {
            _ = refinement.wait(timeout: .now() + minimumDissolveDuration + 0.5)
        }
        return true
    }

    /// Gives whatever the glide left unrefined one last, short correction before the handoff. Returns the animations to wait for.
    private func finishRefinement(
        _ participants: inout [Participant],
        animator: SnapshotAnimating,
        pendingSteer: Set<Int>,
        pendingRecapture: Set<Int>,
        timings: inout SnapshotTimings
    ) -> [DispatchGroup] {
        var refinements: [DispatchGroup] = []
        var recapture = pendingRecapture

        if !pendingSteer.isEmpty {
            waitForWriters(timeout: 0.2)
            // As during the glide, only a window whose application has applied its frame can be read back truthfully; one still
            // waiting on its application would report its old frame and be steered back to where it started. Those are left
            // to placement and the settle.
            let steerable = pendingSteer.filter { writer(for: participants[$0].pid).isIdle }
            if !steerable.isEmpty {
                let group = DispatchGroup()
                group.enter()
                let corrected = steerToAcceptedFrames(animator, &participants, indices: steerable.sorted(), duration: lateCorrectionDuration) { group.leave() }
                timings.corrected += corrected
                if corrected == 0 {
                    group.leave()
                }
                refinements.append(group)
                recapture.formUnion(steerable.filter { refinesInPlace && resizedIndexSet.contains($0) })
            }
        }

        guard !recapture.isEmpty else {
            return refinements
        }

        // Slow renderers get one more moment before the final attempt; whatever still has not redrawn lingers at the handoff.
        sleep(redrawSettleDelay)
        let (group, dissolved) = dissolveToFreshCaptures(animator, participants, indices: recapture.sorted(), duration: minimumDissolveDuration, isFinalAttempt: true)
        refinements.append(contentsOf: [group].compactMap { $0 })
        timings.recaptured += dissolved.count
        timings.unrefreshed = recapture.subtracting(dissolved).sorted()
        return refinements
    }

    /**
     Gets the real windows out of sight and gives them their final size: at their destinations behind the backdrop, or parked beyond the displays.

     - Returns: The indices of windows whose size changes.
     */
    private func hideRealWindows(_ participants: inout [Participant], inPlace: Bool, timings: inout SnapshotTimings) -> [Int] {
        var resizedIndices: [Int] = []

        if inPlace {
            var writes: Writes = [:]
            for index in participants.indices {
                let participant = participants[index]
                let resize = participant.resizable && participant.start.size != participant.target.size
                let frame = CGRect(origin: participant.target.origin, size: resize ? participant.target.size : participant.lastIssued.size)
                writes[participant.pid, default: [:]][index] = .init(window: participant.window, frame: frame, includingSize: resize)
                participants[index].lastIssued = frame
                if resize {
                    resizedIndices.append(index)
                }
            }
            dispatch(writes)
            return resizedIndices
        }

        // Park at the current size first so every window vanishes together, then take the final size out of sight.
        let parking = parkingOrigin()
        var parkWrites: Writes = [:]
        for index in participants.indices {
            let frame = CGRect(origin: CGPoint(x: parking.x, y: participants[index].start.minY), size: participants[index].start.size)
            parkWrites[participants[index].pid, default: [:]][index] = .init(window: participants[index].window, frame: frame, includingSize: false)
            participants[index].lastIssued = frame
        }
        dispatch(parkWrites)
        let parkStart = now()
        waitForWriters(timeout: 0.1)
        timings.parkDuration = now() - parkStart

        var resizeWrites: Writes = [:]
        for index in participants.indices where participants[index].resizable && participants[index].start.size != participants[index].target.size {
            let frame = CGRect(origin: participants[index].lastIssued.origin, size: participants[index].target.size)
            resizeWrites[participants[index].pid, default: [:]][index] = .init(window: participants[index].window, frame: frame, includingSize: true)
            participants[index].lastIssued = frame
            resizedIndices.append(index)
        }
        dispatch(resizeWrites)
        return resizedIndices
    }

    /// Brings the real windows to their targets; only the position changes now. Windows re-laid out in place are already there unless their target was corrected.
    private func placeRealWindows(_ participants: inout [Participant]) -> TimeInterval {
        var writes: Writes = [:]
        for index in participants.indices {
            let frame = CGRect(origin: participants[index].target.origin, size: participants[index].lastIssued.size)
            guard frame != participants[index].lastIssued else {
                continue
            }
            writes[participants[index].pid, default: [:]][index] = .init(window: participants[index].window, frame: frame, includingSize: false)
            participants[index].lastIssued = frame
        }
        dispatch(writes)

        let start = now()
        waitForWriters(timeout: 0.2)
        return now() - start
    }

    /**
     Reads back the frame each window actually took and, for any that differ from the assigned frame, corrects the participant's
     target and steers its proxy there. Applications with minimum or fixed sizes, or ones that refuse to sit under the menu bar,
     would otherwise pop at the handoff.

     Behind a backdrop the window is already at its destination, so its whole frame is authoritative. A parked window's position
     means nothing, so only its size is taken, and the focused window's origin is clamped the way the settle pass will clamp it.

     - Returns: How many proxies were corrected. `completion` is forwarded to the animator only when at least one was.
     */
    private func steerToAcceptedFrames(
        _ animator: SnapshotAnimating,
        _ participants: inout [Participant],
        indices: [Int],
        duration: TimeInterval,
        completion: (() -> Void)?
    ) -> Int {
        var acceptedFrames = [Int: CGRect]()
        let lock = NSLock()
        let windows = indices.map { participants[$0].window }

        DispatchQueue.concurrentPerform(iterations: windows.count) { position in
            // A window whose frame cannot be read keeps the target it has.
            guard let frame = FrameInterpolation.readable(windows[position].frame()) else {
                return
            }
            lock.lock()
            acceptedFrames[indices[position]] = frame
            lock.unlock()
        }

        var corrections = [CGRect?](repeating: nil, count: participants.count)
        for index in indices {
            guard let accepted = acceptedFrames[index] else {
                continue
            }

            // Where the settle pass will leave the window: its accepted frame, kept on screen if it is the focused window.
            let assignment = participants[index].assignment
            let corrected = assignment.keepingFocusedWindowOnScreen(
                refinesInPlace ? accepted : CGRect(origin: participants[index].target.origin, size: accepted.size)
            )

            guard corrected != participants[index].target else {
                continue
            }

            participants[index].target = corrected
            corrections[index] = corrected
        }

        let count = corrections.compactMap { $0 }.count
        guard count > 0 else {
            return 0
        }

        runOnMainSync {
            animator.retarget(frames: corrections, duration: duration, completion: completion)
        }
        return count
    }

    /**
     Captures the given windows again, now that they show their real final rendering, and dissolves their proxies into those images.

     Only an image whose pixel size matches the size the application accepted is used; a window whose application has not
     finished redrawing keeps its old image and is reported back so the caller can try again.

     - Returns: A group that empties when the dissolve has finished, or `nil` if nothing was dissolved, and the indices that received a fresh image.
     */
    private func dissolveToFreshCaptures(
        _ animator: SnapshotAnimating,
        _ participants: [Participant],
        indices: [Int],
        duration: TimeInterval,
        isFinalAttempt: Bool
    ) -> (DispatchGroup?, Set<Int>) {
        let requests = indices.map { WindowCaptureRequest(windowID: participants[$0].window.cgID(), frame: participants[$0].target) }
        guard let captureImages = captureImages, let fresh = captureImages(requests), fresh.count == indices.count else {
            if isFinalAttempt {
                let pids = indices.map { String(participants[$0].pid) }.joined(separator: ", ")
                os_log("Animated reflow: recapture failed for pids %{public}s", log: animationLog, type: .info, pids)
            }
            return (nil, [])
        }

        var images = [CGImage?](repeating: nil, count: participants.count)
        var dissolved = Set<Int>()
        var stale: [String] = []
        for (position, index) in indices.enumerated() {
            let participant = participants[index]
            let image = fresh[position]
            let expectedWidth = participant.target.width * participant.pixelsPerPoint
            let expectedHeight = participant.target.height * participant.pixelsPerPoint

            // A few pixels either way is a border or rounding difference, not a stale surface.
            let tolerance = max(4, 0.005 * max(expectedWidth, expectedHeight))
            guard abs(CGFloat(image.width) - expectedWidth) <= tolerance, abs(CGFloat(image.height) - expectedHeight) <= tolerance else {
                stale.append("pid \(participant.pid) got \(image.width)x\(image.height) expected \(Int(expectedWidth))x\(Int(expectedHeight))")
                continue
            }

            images[index] = image
            dissolved.insert(index)
        }

        if isFinalAttempt, !stale.isEmpty {
            os_log("Animated reflow: window still not redrawn at handoff, keeping old image: %{public}s", log: animationLog, type: .info, stale.joined(separator: "; "))
        }

        guard !dissolved.isEmpty else {
            return (nil, [])
        }

        let group = DispatchGroup()
        group.enter()
        runOnMainSync {
            animator.crossfade(images: images, duration: duration) {
                group.leave()
            }
        }
        return (group, dissolved)
    }

    /**
     Leaves every real window at a valid tile, remembers where its proxy was last seen so a follow-up animation can start there,
     and removes the overlay.

     The reflow that cancelled this operation may return without doing anything, for instance when tiling was just turned off,
     so the windows must not be left at mid-animation positions. Windows re-laid out in place are already at their tiles.
     */
    private func abandonSnapshotAnimation(_ animator: SnapshotAnimating, _ participants: inout [Participant]) -> SnapshotOutcome {
        var currentFrames: [CGRect] = []
        runOnMainSync {
            currentFrames = animator.presentationFrames()
        }

        var lastSeen: [CGWindowID: CGRect] = [:]
        for index in participants.indices where index < currentFrames.count {
            if let frame = FrameInterpolation.readable(currentFrames[index]) {
                lastSeen[participants[index].window.cgID()] = frame
            }
        }
        AnimatingWindows.shared.recordLastSeenFrames(lastSeen, at: now())

        writers.values.forEach { $0.discardPending() }
        placeAtTargets(&participants)

        runOnMainSync {
            animator.cancel()
        }

        return .cancelled
    }

    /// Puts every window at its target's position, keeping whatever size it has; skips windows already there.
    private func placeAtTargets(_ participants: inout [Participant]) {
        var writes: Writes = [:]
        for index in participants.indices {
            let frame = CGRect(origin: participants[index].target.origin, size: participants[index].lastIssued.size)
            guard frame != participants[index].lastIssued else {
                continue
            }
            writes[participants[index].pid, default: [:]][index] = .init(window: participants[index].window, frame: frame, includingSize: false)
            participants[index].lastIssued = frame
        }
        dispatch(writes)
        waitForWriters(timeout: 0.3)
    }

    // MARK: - Accessibility strategy

    /// Phase one: give every window its final size at its current position, so the glide only has to move it. Waits for every application so all windows start gliding together.
    private func resizeInPlace(_ participants: inout [Participant]) {
        var writes: Writes = [:]

        for index in participants.indices {
            let participant = participants[index]

            guard participant.resizable, participant.start.size != participant.target.size else {
                continue
            }

            let frame = CGRect(origin: participant.start.origin, size: participant.target.size)
            writes[participant.pid, default: [:]][index] = .init(window: participant.window, frame: frame, includingSize: true)
            participants[index].lastIssued = frame
        }

        dispatch(writes)
        waitForWriters()
        writers.values.forEach { $0.resetStatistics() }

        // Applications may keep a different size than assigned; the glide must clamp and land with the size they kept.
        for index in participants.indices where participants[index].resizable {
            guard let accepted = FrameInterpolation.readable(participants[index].window.frame()) else {
                continue
            }
            participants[index].lastIssued.size = accepted.size
            participants[index].target.size = accepted.size
        }
    }

    /// Phase two: drive the positions. Returns `false` if the operation was cancelled before the glide finished.
    private func animate(_ participants: inout [Participant], resizeDuration: TimeInterval) -> Bool {
        let animationStart = now()

        while true {
            let tickStart = now()
            let elapsed = tickStart - animationStart

            guard elapsed < duration else {
                break
            }

            guard !isCancelled else {
                abandonPendingWrites(&participants)
                return false
            }

            let progress = FrameInterpolation.easeInOutSine(CGFloat(elapsed / duration))
            var writes: Writes = [:]

            for index in participants.indices {
                let frame = participants[index].frame(at: progress)

                guard frame != participants[index].lastIssued else {
                    continue
                }

                writes[participants[index].pid, default: [:]][index] = .init(window: participants[index].window, frame: frame, includingSize: false)
                participants[index].lastIssued = frame
            }

            dispatch(writes)
            tickCount += 1

            let nextTick = tickStart + frameInterval
            let tickEnd = now()
            if nextTick > tickEnd {
                sleep(nextTick - tickEnd)
            }

            if isCancelled {
                abandonPendingWrites(&participants)
                return false
            }
        }

        let drained = waitForWriters()
        logAccessibilityTiming(resizeDuration: resizeDuration, drained: drained)
        return true
    }

    /// Drops frames not yet applied and leaves every window at its tile, since the reflow that cancelled this glide may not move it.
    private func abandonPendingWrites(_ participants: inout [Participant]) {
        writers.values.forEach { $0.discardPending() }
        waitForWriters()
        placeAtTargets(&participants)
    }

    // MARK: - Ownership

    /**
     Whether this operation may still move the window.

     A window Amethyst has since relocated to another screen or Space, or that another screen's animation has claimed, was handed off: writing its old tile back would undo the move. Operations without a screen have no claims and own everything.
     */
    private func owns(_ window: Window) -> Bool {
        guard let screenID = screenID else {
            return true
        }
        return AnimatingWindows.shared.screenID(for: window.cgID()) == screenID
    }

    /// Finds participants handed off since the last check and hides their proxies so they do not glide on as ghosts.
    private func retireHandedOffProxies(_ participants: [Participant], alreadyRetired: inout Set<Int>, animator: SnapshotAnimating) -> Set<Int> {
        let retired = Set(participants.indices.filter { !alreadyRetired.contains($0) && !owns(participants[$0].window) })
        guard !retired.isEmpty else {
            return []
        }
        alreadyRetired.formUnion(retired)
        runOnMainSync {
            animator.hide(indices: retired.sorted())
        }
        return retired
    }

    // MARK: - Writers

    /// Issues the writes, leaving out windows this operation no longer owns.
    private func dispatch(_ writes: Writes) {
        for (pid, applicationWrites) in writes {
            let owned = applicationWrites.filter { owns($0.value.window) }
            guard !owned.isEmpty else {
                continue
            }
            writer(for: pid).write(owned)
        }
    }

    private func writer(for pid: pid_t) -> ApplicationFrameWriter<Window> {
        if let writer = writers[pid] {
            return writer
        }

        let writer = ApplicationFrameWriter<Window>(pid: pid, group: writerGroup, inline: writesInline, now: now)
        writers[pid] = writer
        return writer
    }

    /// Waits for every application to apply its newest frame. Returns `false` if a slow application timed out.
    @discardableResult
    private func waitForWriters(timeout: TimeInterval = writerDrainTimeout) -> Bool {
        return writerGroup.wait(timeout: .now() + timeout) == .success
    }

    // MARK: - Logging

    private func logSnapshotTiming(windowCount: Int, timings: SnapshotTimings) {
        let mode = timings.inPlace ? "in place" : "parked"
        let capture = Int(timings.captureDuration * 1000)
        let park = Int(timings.parkDuration * 1000)
        let place = Int(timings.placeDuration * 1000)
        let firstRefinement = Int((timings.firstRefinement ?? -0.001) * 1000)
        log.debug(
            "Animated reflow (snapshot, \(mode)): \(windowCount) windows, capture \(capture)ms, park \(park)ms, glide \(duration)s, place \(place)ms, "
                + "\(timings.corrected) size-corrected, \(timings.recaptured) recaptured, first refinement at \(firstRefinement)ms"
        )
        os_log(
            "Animated reflow (snapshot, %{public}s): %d windows, capture %dms, park %dms, glide %.2fs, place %dms, %d size-corrected, %d recaptured, first refinement at %dms",
            log: animationLog, type: .info, mode, windowCount, capture, park, duration, place, timings.corrected, timings.recaptured, firstRefinement
        )
    }

    private func logAccessibilityTiming(resizeDuration: TimeInterval, drained: Bool) {
        guard tickCount > 0 else {
            return
        }

        let framesPerSecond = Int((Double(tickCount) / duration).rounded())
        let resizeMilliseconds = Int(resizeDuration * 1000)
        let slowest = writers.values
            .map { (pid: $0.pid, statistics: $0.statisticsSnapshot()) }
            .max { $0.statistics.averageWriteTime < $1.statistics.averageWriteTime }
        let slowestPid = slowest?.pid ?? 0
        let slowestAverageMilliseconds = Int((slowest?.statistics.averageWriteTime ?? 0) * 1000)
        let slowestApplied = slowest?.statistics.applied ?? 0
        let slowestRequested = slowest?.statistics.requested ?? 0
        let timeoutNote = drained ? "" : "; timed out waiting for it"

        log.debug(
            "Animated reflow (accessibility): resize \(resizeMilliseconds)ms, then \(tickCount) ticks over \(duration)s (\(framesPerSecond) fps); "
                + "slowest app pid \(slowestPid) averaged \(slowestAverageMilliseconds)ms per write and showed \(slowestApplied) of \(slowestRequested) frames\(timeoutNote)"
        )
        os_log(
            "Animated reflow (accessibility): resize %dms, then %d ticks over %.2fs (%d fps); slowest app pid %d averaged %dms per write and showed %d of %d frames%{public}s",
            log: animationLog, type: .info,
            resizeMilliseconds, tickCount, duration, framesPerSecond, slowestPid, slowestAverageMilliseconds, slowestApplied, slowestRequested, timeoutNote
        )
    }
}
