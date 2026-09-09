//
//  AnimatedReflowOperationTests.swift
//  AmethystTests
//
//  Created by Don Patterson on 9/8/26.
//  Copyright © 2026 Ian Ynda-Hummel. All rights reserved.
//

@testable import Amethyst
import CoreGraphics
import Nimble
import Quick
import Silica

class AnimatedReflowOperationTests: QuickSpec {
    /// A deterministic clock: every sleep advances time by exactly the requested amount.
    private final class FakeClock {
        private(set) var time: TimeInterval = 0
        private(set) var sleepCount = 0
        var onSleep: ((Int) -> Void)?

        func now() -> TimeInterval {
            return time
        }

        func sleep(_ interval: TimeInterval) {
            time += interval
            sleepCount += 1
            onSleep?(sleepCount)
        }
    }

    private struct Fixture {
        let windows: [TestWindow]
        let operations: [FrameAssignmentOperation<TestWindow>]
    }

    /// Records the overlay calls the operation makes and completes the glide immediately unless told otherwise.
    private final class FakeSnapshotAnimator: SnapshotAnimating {
        var shownProxies: [SnapshotProxy] = []
        var shownScreenFrame: CGRect?
        var animateDuration: TimeInterval?
        var completesImmediately = true
        var onAnimate: (() -> Void)?
        var framesToPresent: [CGRect] = []
        var finishCalled = false
        var lingering: [Int] = []
        var cancelCalled = false
        var retargetedFrames: [[CGRect?]] = []
        var retargetDurations: [TimeInterval] = []
        var shownBackdrop: CGImage?
        var crossfadeImages: [[CGImage?]] = []
        var crossfadeDurations: [TimeInterval] = []
        private var pendingCompletion: (() -> Void)?

        func show(proxies: [SnapshotProxy], screenFrame: CGRect, backdrop: CGImage?) {
            shownProxies = proxies
            shownScreenFrame = screenFrame
            shownBackdrop = backdrop
        }

        /// Any mid-glide refinement stands in for the real overlay reaching its target and ends the pending glide.
        private func endPendingGlide() {
            let pending = pendingCompletion
            pendingCompletion = nil
            pending?()
        }

        func crossfade(images: [CGImage?], duration: TimeInterval, completion: (() -> Void)?) {
            crossfadeImages.append(images)
            crossfadeDurations.append(duration)
            completion?()
            endPendingGlide()
        }

        func animate(duration: TimeInterval, completion: @escaping () -> Void) {
            animateDuration = duration
            onAnimate?()
            if completesImmediately {
                completion()
            } else {
                pendingCompletion = completion
            }
        }

        /// A late correction completes at once; a mid-glide retarget ends the pending glide.
        func retarget(frames: [CGRect?], duration: TimeInterval, completion: (() -> Void)?) {
            retargetedFrames.append(frames)
            retargetDurations.append(duration)
            if let completion = completion {
                completion()
            } else {
                endPendingGlide()
            }
        }

        func presentationFrames() -> [CGRect] {
            return framesToPresent
        }

        func finish(fadeDuration: TimeInterval, lingering: [Int], lingerDuration: TimeInterval, completion: @escaping () -> Void) {
            finishCalled = true
            self.lingering = lingering
            completion()
        }

        func cancel() {
            cancelCalled = true
        }
    }

    private static func makeImage(width: Int = 1, height: Int = 1) -> CGImage {
        let context = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        return context.makeImage()!
    }

    private let parkingOrigin = CGPoint(x: 5000, y: 0)

    private func makeSnapshotOperation(
        _ fixture: Fixture,
        clock: FakeClock,
        animator: FakeSnapshotAnimator,
        capture: @escaping ([WindowCaptureRequest]) -> [CGImage]?,
        backdrop: ((CGRect, [CGWindowID]) -> CGImage?)? = nil
    ) -> AnimatedReflowOperation<TestWindow> {
        return AnimatedReflowOperation(
            frameAssignmentOperations: fixture.operations,
            duration: duration,
            frameInterval: frameInterval,
            writesInline: true,
            captureImages: capture,
            captureBackdrop: backdrop,
            makeSnapshotAnimator: { animator },
            parkingOrigin: { self.parkingOrigin },
            now: clock.now,
            sleep: clock.sleep
        )
    }

    // Exactly representable in binary so the tick count is deterministic: 8 ticks at 0, 1/32 ... 7/32.
    private let duration: TimeInterval = 0.25
    private let frameInterval: TimeInterval = 1.0 / 32.0
    private let expectedTicks = 8

    private func makeFixture(startFrames: [CGRect], targetFrames: [CGRect], focusedIndex: Int? = nil) -> Fixture {
        let screenFrame = CGRect(x: 0, y: 0, width: 2000, height: 1000)
        let windows: [TestWindow] = startFrames.enumerated().map { index, frame in
            let window = TestWindow(element: nil)!
            window.setFrame(frame, withThreshold: .zero)
            window.isFocusedValue = index == focusedIndex
            window.clearFrameHistory()
            return window
        }
        let layoutWindows = windows.map {
            LayoutWindow<TestWindow>(id: $0.id(), frame: $0.frame(), isFocused: $0.isFocused())
        }
        let windowSet = WindowSet<TestWindow>(
            windows: layoutWindows,
            isWindowWithIDActive: { _ in return true },
            isWindowWithIDFloating: { _ in return false },
            windowForID: { id in return windows.first { $0.id() == id } }
        )
        let resizeRules = ResizeRules(isMain: true, unconstrainedDimension: .horizontal, scaleFactor: 1)
        let operations = zip(layoutWindows, targetFrames).map { layoutWindow, target in
            FrameAssignmentOperation(
                frameAssignment: FrameAssignment(frame: target, window: layoutWindow, screenFrame: screenFrame, resizeRules: resizeRules),
                windowSet: windowSet
            )
        }
        return Fixture(windows: windows, operations: operations)
    }

    private func makeOperation(_ fixture: Fixture, clock: FakeClock) -> AnimatedReflowOperation<TestWindow> {
        return AnimatedReflowOperation(
            frameAssignmentOperations: fixture.operations,
            duration: duration,
            frameInterval: frameInterval,
            writesInline: true,
            now: clock.now,
            sleep: clock.sleep
        )
    }

    /// Whether `values` never reverses direction on its way from the first element to the last.
    private func isMonotonic(_ values: [CGFloat]) -> Bool {
        guard let first = values.first, let last = values.last else {
            return true
        }
        let increasing = last >= first
        return zip(values, values.dropFirst()).allSatisfy { increasing ? $1 >= $0 : $1 <= $0 }
    }

    override func spec() {
        describe("easing") {
            it("starts at zero and ends at one") {
                expect(FrameInterpolation.easeInOutSine(0)) == 0
                expect(FrameInterpolation.easeInOutSine(1)).to(beCloseTo(1))
            }

            it("is monotonic, symmetric, and gentle at both ends") {
                let samples = (0...100).map { FrameInterpolation.easeInOutSine(CGFloat($0) / 100) }
                expect(self.isMonotonic(samples)).to(beTrue())
                expect(FrameInterpolation.easeInOutSine(0.5)).to(beCloseTo(0.5))
                expect(FrameInterpolation.easeInOutSine(0.1)) < 0.1
                expect(FrameInterpolation.easeInOutSine(0.9)) > 0.9
            }

            it("clamps out-of-range progress") {
                expect(FrameInterpolation.easeInOutSine(-1)) == 0
                expect(FrameInterpolation.easeInOutSine(2)).to(beCloseTo(1))
            }
        }

        describe("interpolation") {
            let start = CGRect(x: 0, y: 0, width: 100, height: 100)
            let end = CGRect(x: 200, y: 100, width: 300, height: 50)

            it("returns the endpoints at zero and one") {
                expect(FrameInterpolation.interpolate(from: start, to: end, progress: 0)) == start
                expect(FrameInterpolation.interpolate(from: start, to: end, progress: 1)) == end
            }

            it("produces integral intermediate frames") {
                let odd = CGRect(x: 1, y: 1, width: 101, height: 101)
                let mid = FrameInterpolation.interpolate(from: start, to: odd, progress: 0.5)
                for value in [mid.minX, mid.minY, mid.width, mid.height] {
                    expect(value) == value.rounded()
                }
            }
        }

        describe("application frame writer") {
            func makeWrite(_ window: TestWindow, xPosition: CGFloat) -> ApplicationFrameWriter<TestWindow>.Write {
                return .init(window: window, frame: CGRect(x: xPosition, y: 0, width: 100, height: 100), includingSize: false)
            }

            it("applies every frame when writing inline") {
                let window = TestWindow(element: nil)!
                let group = DispatchGroup()
                let writer = ApplicationFrameWriter<TestWindow>(pid: 1, group: group, inline: true, now: { 0 })

                for step in 1...5 {
                    writer.write([0: makeWrite(window, xPosition: CGFloat(step))])
                }

                expect(window.frameHistory.map { $0.minX }) == [1, 2, 3, 4, 5]
                expect(writer.statisticsSnapshot().applied) == 5
                expect(writer.statisticsSnapshot().requested) == 5
                expect(group.wait(timeout: .now())) == .success
            }

            it("drops frames a slow application cannot keep up with but always lands on the newest") {
                let window = TestWindow(element: nil)!
                window.animationFrameDelay = 0.03
                let group = DispatchGroup()
                let writer = ApplicationFrameWriter<TestWindow>(pid: 1, group: group, inline: false, now: { ProcessInfo.processInfo.systemUptime })

                // Ten frames arrive faster than the window can apply them.
                for step in 1...10 {
                    writer.write([0: makeWrite(window, xPosition: CGFloat(step))])
                    Thread.sleep(forTimeInterval: 0.002)
                }

                expect(group.wait(timeout: .now() + 2)) == .success
                let statistics = writer.statisticsSnapshot()
                expect(statistics.requested) == 10
                expect(statistics.applied) < 10
                expect(window.frame().minX) == 10
                expect(self.isMonotonic(window.frameHistory.map { $0.minX })).to(beTrue())
            }

            it("forgets discarded frames") {
                let window = TestWindow(element: nil)!
                window.animationFrameDelay = 0.03
                let group = DispatchGroup()
                let writer = ApplicationFrameWriter<TestWindow>(pid: 1, group: group, inline: false, now: { ProcessInfo.processInfo.systemUptime })

                writer.write([0: makeWrite(window, xPosition: 1)])
                Thread.sleep(forTimeInterval: 0.005)
                writer.write([0: makeWrite(window, xPosition: 2)])
                writer.discardPending()

                expect(group.wait(timeout: .now() + 2)) == .success
                expect(window.frame().minX) == 1
            }
        }

        describe("coordinates and parking") {
            it("flips between AppKit and Accessibility coordinates and back") {
                let flipped = CGRect(x: 10, y: 20, width: 100, height: 50)
                let appKit = FlippedCoordinates.appKitRect(fromFlipped: flipped, primaryScreenHeight: 1000)
                expect(appKit) == CGRect(x: 10, y: 930, width: 100, height: 50)
                expect(FlippedCoordinates.flippedRect(fromAppKit: appKit, primaryScreenHeight: 1000)) == flipped
            }

            it("parks windows to the right of every display") {
                let displays = [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: -962, y: -1600, width: 3840, height: 1600)]
                let origin = AnimatedReflowOperation<TestWindow>.parkingOrigin(forDisplayBounds: displays)
                expect(origin.x) == 2878 + 200
            }

            it("finds the display a screen frame lies on") {
                let displays = [CGRect(x: 0, y: 0, width: 1728, height: 1117), CGRect(x: -962, y: -1600, width: 3840, height: 1600)]
                let external = CGRect(x: -962, y: -1570, width: 3840, height: 1570)
                expect(WindowImageCapture.displayBounds(containing: external, among: displays)) == displays[1]
                expect(WindowImageCapture.displayBounds(containing: CGRect(x: 5000, y: 0, width: 10, height: 10), among: displays)).to(beNil())
            }
        }

        describe("animating windows registry") {
            it("keeps a window with the screen animating it until that screen releases it") {
                let registry = AnimatingWindows()
                registry.claim([1, 2], for: "external")
                expect(registry.screenID(for: 1)) == "external"
                expect(registry.screenID(for: 3)).to(beNil())

                // Another screen's release must not disturb the claim.
                registry.release([1], for: "builtin")
                expect(registry.screenID(for: 1)) == "external"

                registry.release([1, 2], for: "external")
                expect(registry.screenID(for: 1)).to(beNil())
                expect(registry.screenID(for: 2)).to(beNil())
            }
        }

        describe("snapshot animation") {
            let startFrames = [
                CGRect(x: 0, y: 0, width: 1000, height: 1000),
                CGRect(x: 1000, y: 0, width: 1000, height: 1000)
            ]
            let targetFrames = [
                CGRect(x: 0, y: 0, width: 500, height: 1000),
                CGRect(x: 500, y: 0, width: 1500, height: 1000)
            ]
            let captureAll: ([WindowCaptureRequest]) -> [CGImage]? = { requests in requests.map { _ in AnimatedReflowOperationTests.makeImage() } }

            it("parks, resizes out of sight, places, and settles each window") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: captureAll)

                operation.main()

                for (index, window) in fixture.windows.enumerated() {
                    let start = startFrames[index]
                    let target = fixture.operations[index].frameAssignment.finalFrame
                    let parked = CGPoint(x: self.parkingOrigin.x, y: start.minY)

                    expect(window.frameHistory) == [
                        CGRect(origin: parked, size: start.size),
                        CGRect(origin: parked, size: target.size),
                        CGRect(origin: target.origin, size: target.size),
                        target
                    ]
                }

                expect(operation.tickCount) == 0
                expect(clock.sleepCount) == 1
                expect(animator.finishCalled).to(beTrue())
                expect(animator.cancelCalled).to(beFalse())
            }

            it("hands the overlay the start and target frames and the duration") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: captureAll)

                operation.main()

                expect(animator.shownProxies.map { $0.start }) == startFrames
                expect(animator.shownProxies.map { $0.target }) == fixture.operations.map { FrameInterpolation.integral($0.frameAssignment.finalFrame) }
                expect(animator.shownScreenFrame) == fixture.operations[0].frameAssignment.screenFrame
                expect(animator.animateDuration) == self.duration
            }

            it("falls back to moving the real windows when capture fails") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: { _ in nil })

                operation.main()

                expect(animator.shownProxies).to(beEmpty())
                expect(operation.tickCount) == self.expectedTicks
                // The accessibility strategy starts with the in-place resize.
                expect(fixture.windows[1].frameHistory.first) == CGRect(origin: startFrames[1].origin, size: fixture.operations[1].frameAssignment.finalFrame.size)
            }

            it("falls back when capture returns the wrong number of images") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: { _ in [AnimatedReflowOperationTests.makeImage()] })

                operation.main()

                expect(animator.shownProxies).to(beEmpty())
                expect(operation.tickCount) == self.expectedTicks
            }

            it("re-lays out windows in place behind a backdrop and dissolves proxies into fresh captures") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                animator.completesImmediately = false
                // Captures are sized like the windows they picture, one pixel per point, so a fresh capture matches the accepted size.
                let captureCurrent: ([WindowCaptureRequest]) -> [CGImage]? = { requests in
                    requests.indices.map { position in
                        let size = fixture.windows[position].frame().size
                        return AnimatedReflowOperationTests.makeImage(width: Int(size.width), height: Int(size.height))
                    }
                }
                var excludedFromBackdrop: [CGWindowID] = []
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: captureCurrent, backdrop: { _, ids in
                    excludedFromBackdrop = ids
                    return AnimatedReflowOperationTests.makeImage(width: 4, height: 4)
                })

                operation.main()

                expect(animator.shownBackdrop).toNot(beNil())
                expect(excludedFromBackdrop) == fixture.windows.map { $0.cgID() }

                // No parking: each window goes straight to its destination at its final size, then settles.
                for (index, window) in fixture.windows.enumerated() {
                    let target = fixture.operations[index].frameAssignment.finalFrame
                    expect(window.frameHistory) == [target, target]
                }

                expect(animator.retargetedFrames).to(beEmpty())
                expect(animator.crossfadeImages.count) == 1
                expect(animator.crossfadeImages[0].compactMap { $0 }.count) == 2
                expect(animator.crossfadeDurations[0]) <= self.duration
                expect(animator.finishCalled).to(beTrue())
            }

            it("corrects the size and still dissolves when an application constrains its window in place") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let constrained = fixture.windows[1]
                constrained.maximumSize = CGSize(width: 1200, height: 1000)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                animator.completesImmediately = false
                let captureCurrent: ([WindowCaptureRequest]) -> [CGImage]? = { requests in
                    requests.indices.map { position in
                        let size = fixture.windows[position].frame().size
                        return AnimatedReflowOperationTests.makeImage(width: Int(size.width), height: Int(size.height))
                    }
                }
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: captureCurrent, backdrop: { _, _ in
                    AnimatedReflowOperationTests.makeImage(width: 4, height: 4)
                })

                operation.main()

                let target = fixture.operations[1].frameAssignment.finalFrame
                let accepted = CGRect(origin: target.origin, size: CGSize(width: 1200, height: 1000))
                expect(animator.retargetedFrames.count) == 1
                expect(animator.retargetedFrames[0][1]) == accepted
                expect(animator.crossfadeImages.count) == 1
                expect(animator.crossfadeImages[0][1]?.width) == 1200
                expect(constrained.frame()) == accepted
            }

            it("retries a recapture until the window has redrawn at its accepted size") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                animator.completesImmediately = false
                var captureCalls = 0
                // The second window's first recapture still shows its old surface, the way a slow renderer does.
                let captureLagging: ([WindowCaptureRequest]) -> [CGImage]? = { requests in
                    captureCalls += 1
                    return requests.indices.map { position in
                        let window = fixture.windows[requests.count == fixture.windows.count ? position : 1]
                        var size = window.frame().size
                        if captureCalls == 2, position == 1 {
                            size = startFrames[1].size
                        }
                        return AnimatedReflowOperationTests.makeImage(width: Int(size.width), height: Int(size.height))
                    }
                }
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: captureLagging, backdrop: { _, _ in
                    AnimatedReflowOperationTests.makeImage(width: 4, height: 4)
                })

                operation.main()

                expect(captureCalls) == 3
                expect(animator.crossfadeImages.count) == 2
                expect(animator.crossfadeImages[0][0]).toNot(beNil())
                expect(animator.crossfadeImages[0][1]).to(beNil())
                expect(animator.crossfadeImages[1][1]?.width) == Int(fixture.operations[1].frameAssignment.finalFrame.width)
                expect(animator.finishCalled).to(beTrue())
                expect(animator.lingering).to(beEmpty())
            }

            it("lets a proxy linger at the handoff when its window never redraws") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                animator.completesImmediately = false
                var captureCalls = 0
                // The second window's surface never changes, the way an app that does not repaint while covered behaves.
                let captureStuck: ([WindowCaptureRequest]) -> [CGImage]? = { requests in
                    captureCalls += 1
                    return requests.indices.map { position in
                        let isInitialCapture = requests.count == fixture.windows.count
                        let windowIndex = isInitialCapture ? position : 1
                        let size = captureCalls == 1 || windowIndex == 0 ? fixture.windows[windowIndex].frame().size : startFrames[1].size
                        return AnimatedReflowOperationTests.makeImage(width: Int(size.width), height: Int(size.height))
                    }
                }
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: captureStuck, backdrop: { _, _ in
                    AnimatedReflowOperationTests.makeImage(width: 4, height: 4)
                })

                operation.main()

                expect(animator.crossfadeImages.count) == 1
                expect(animator.crossfadeImages[0][1]).to(beNil())
                expect(animator.lingering) == [1]
                expect(animator.finishCalled).to(beTrue())
            }

            it("captures a window that overhangs the display edge whole and asks for it at its current frame") {
                // A window too wide for its tile, like Mail, ends up 100 points past the right edge of the display.
                let fixture = self.makeFixture(startFrames: [CGRect(x: 0, y: 0, width: 1100, height: 1000)], targetFrames: [CGRect(x: 1000, y: 0, width: 1000, height: 1000)])
                let window = fixture.windows[0]
                window.minimumSize = CGSize(width: 1100, height: 1000)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                animator.completesImmediately = false
                var requestedFrames: [CGRect] = []
                let captureWhole: ([WindowCaptureRequest]) -> [CGImage]? = { requests in
                    requests.map { request in
                        requestedFrames.append(request.frame)
                        let size = window.frame().size
                        return AnimatedReflowOperationTests.makeImage(width: Int(size.width), height: Int(size.height))
                    }
                }
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: captureWhole, backdrop: { _, _ in
                    AnimatedReflowOperationTests.makeImage(width: 4, height: 4)
                })

                operation.main()

                let landed = CGRect(x: 1000, y: 0, width: 1100, height: 1000)
                expect(window.frame()) == landed
                expect(requestedFrames.first) == CGRect(x: 0, y: 0, width: 1100, height: 1000)
                expect(requestedFrames.last) == landed
                expect(animator.retargetedFrames.count) == 1
                expect(animator.retargetedFrames[0][0]) == landed
                expect(animator.crossfadeImages.count) == 1
                expect(animator.crossfadeImages[0][0]?.width) == 1100
                expect(animator.lingering).to(beEmpty())
            }

            it("steers a proxy to where its window actually lands when the application refuses a position") {
                let fixture = self.makeFixture(startFrames: [CGRect(x: 0, y: 500, width: 1000, height: 500)], targetFrames: [CGRect(x: 0, y: 0, width: 1000, height: 500)])
                let window = fixture.windows[0]
                window.minimumY = 30
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                animator.completesImmediately = false
                let captureFixed: ([WindowCaptureRequest]) -> [CGImage]? = { requests in
                    requests.map { _ in AnimatedReflowOperationTests.makeImage(width: 1000, height: 500) }
                }
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: captureFixed, backdrop: { _, _ in
                    AnimatedReflowOperationTests.makeImage(width: 4, height: 4)
                })

                operation.main()

                let landed = CGRect(x: 0, y: 30, width: 1000, height: 500)
                expect(animator.retargetedFrames.count) == 1
                expect(animator.retargetedFrames[0][0]) == landed
                expect(window.frame()) == landed
            }

            it("steers a proxy to the size its application actually accepts") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let constrained = fixture.windows[1]
                constrained.maximumSize = CGSize(width: 1200, height: 1000)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                animator.completesImmediately = false
                let operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: captureAll)

                operation.main()

                let target = fixture.operations[1].frameAssignment.finalFrame
                let accepted = CGRect(origin: target.origin, size: CGSize(width: 1200, height: 1000))

                // Only the constrained window is corrected, to its accepted size at the assigned position.
                expect(animator.retargetedFrames.count) == 1
                expect(animator.retargetedFrames[0][0]).to(beNil())
                expect(animator.retargetedFrames[0][1]) == accepted
                expect(animator.retargetDurations[0]) <= self.duration
                expect(constrained.frame()) == accepted
                expect(animator.finishCalled).to(beTrue())
                // Parked windows cannot be captured, so no dissolve happens in this mode.
                expect(animator.crossfadeImages).to(beEmpty())
            }

            it("leaves windows where the user saw them when cancelled mid-glide") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let animator = FakeSnapshotAnimator()
                animator.completesImmediately = false
                let midway = [
                    CGRect(x: 0, y: 0, width: 500, height: 1000),
                    CGRect(x: 750, y: 0, width: 1500, height: 1000)
                ]
                animator.framesToPresent = midway
                var operation: AnimatedReflowOperation<TestWindow>!
                animator.onAnimate = { operation.cancel() }
                operation = self.makeSnapshotOperation(fixture, clock: clock, animator: animator, capture: captureAll)

                operation.main()

                expect(animator.cancelCalled).to(beTrue())
                expect(animator.finishCalled).to(beFalse())
                let moved = fixture.windows[1]
                expect(moved.frame().origin) == midway[1].origin
                expect(moved.frame()) != fixture.operations[1].frameAssignment.finalFrame
            }
        }

        describe("animated reflow") {
            let startFrames = [
                CGRect(x: 0, y: 0, width: 1000, height: 1000),
                CGRect(x: 1000, y: 0, width: 1000, height: 1000)
            ]
            let targetFrames = [
                CGRect(x: 0, y: 0, width: 500, height: 1000),
                CGRect(x: 500, y: 0, width: 1500, height: 1000)
            ]

            it("moves every window together to its final frame") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let operation = self.makeOperation(fixture, clock: clock)

                operation.main()

                expect(operation.tickCount) == self.expectedTicks

                for (index, window) in fixture.windows.enumerated() {
                    let target = fixture.operations[index].frameAssignment.finalFrame
                    // Windows first take their final size in place, then glide: every frame lies within that envelope.
                    let resizedInPlace = CGRect(origin: startFrames[index].origin, size: target.size)
                    let bounds = startFrames[index].union(target).union(resizedInPlace)

                    expect(window.frame()) == target
                    // Window 0 only changes size, so it is done after the in-place resize plus the settle; window 1 also glides.
                    if startFrames[index].origin == target.origin {
                        expect(window.frameHistory.count) == 2
                    } else {
                        expect(window.frameHistory.count) > 2
                    }

                    for frame in window.frameHistory {
                        expect(bounds.contains(frame)).to(beTrue())
                    }

                    let history = [startFrames[index]] + window.frameHistory
                    expect(self.isMonotonic(history.map { $0.minX })).to(beTrue())
                    expect(self.isMonotonic(history.map { $0.minY })).to(beTrue())
                    expect(self.isMonotonic(history.map { $0.width })).to(beTrue())
                    expect(self.isMonotonic(history.map { $0.height })).to(beTrue())
                }
            }

            it("starts gently") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let operation = self.makeOperation(fixture, clock: clock)

                operation.main()

                let window = fixture.windows[1]
                let target = fixture.operations[1].frameAssignment.finalFrame
                let totalTravel = abs(target.minX - startFrames[1].minX)
                // frameHistory[0] is the in-place resize; frameHistory[1] is the first glide frame.
                let firstStep = abs(window.frameHistory[1].minX - startFrames[1].minX)

                expect(firstStep) < totalTravel / 10
            }

            it("resizes each window once in place, then only moves it") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let operation = self.makeOperation(fixture, clock: clock)

                operation.main()

                let window = fixture.windows[1]
                let target = fixture.operations[1].frameAssignment.finalFrame
                let history = window.frameHistory

                // First write: final size at the original position, issued before the clock started.
                expect(history.first) == CGRect(origin: startFrames[1].origin, size: target.size)
                expect(clock.sleepCount) == operation.tickCount

                // Every glide frame keeps that size; only the settle pass at the very end may differ by rounding.
                for frame in history.dropFirst().dropLast() {
                    expect(frame.size) == target.size
                }
                expect(Set(history.map { "\($0.minX),\($0.minY)" }).count) > 4
            }

            it("skips windows that are already in place") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: [startFrames[0], targetFrames[1]])
                let clock = FakeClock()
                let operation = self.makeOperation(fixture, clock: clock)

                operation.main()

                // The unchanged window only receives the settle pass; the moving window animates.
                expect(fixture.windows[0].frameHistory.count) == 1
                expect(fixture.windows[1].frameHistory.count) > 2
            }

            it("does nothing but settle when no window needs to move") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: startFrames)
                let clock = FakeClock()
                let operation = self.makeOperation(fixture, clock: clock)

                operation.main()

                expect(operation.tickCount) == 0
                expect(clock.sleepCount) == 0
                expect(fixture.windows.map { $0.frameHistory.count }) == [1, 1]
            }

            it("stops without settling when cancelled") {
                let fixture = self.makeFixture(startFrames: startFrames, targetFrames: targetFrames)
                let clock = FakeClock()
                let operation = self.makeOperation(fixture, clock: clock)
                clock.onSleep = { count in
                    if count == 3 {
                        operation.cancel()
                    }
                }

                operation.main()

                expect(operation.tickCount) == 3
                // The moving window is caught mid-glide and never receives the settle pass.
                expect(fixture.windows[1].frame()) != fixture.operations[1].frameAssignment.finalFrame
            }

            it("keeps the focused window on screen") {
                // The target hangs off the right edge of the 2000pt screen; the focused window must be clamped every tick.
                let offscreenTarget = CGRect(x: 1600, y: 0, width: 800, height: 1000)
                let fixture = self.makeFixture(startFrames: [startFrames[0]], targetFrames: [offscreenTarget], focusedIndex: 0)
                let clock = FakeClock()
                let operation = self.makeOperation(fixture, clock: clock)

                operation.main()

                // Every animated frame (all but the settle pass at the end) stays within the screen.
                for frame in fixture.windows[0].frameHistory.dropLast() {
                    expect(frame.maxX) <= 2000
                }
            }

            it("finishes immediately with no assignments") {
                let clock = FakeClock()
                let operation = AnimatedReflowOperation<TestWindow>(
                    frameAssignmentOperations: [],
                    duration: self.duration,
                    frameInterval: self.frameInterval,
                    writesInline: true,
                    now: clock.now,
                    sleep: clock.sleep
                )

                operation.main()

                expect(operation.tickCount) == 0
                expect(operation.isFinished).to(beFalse()) // main() was called directly; only a queue marks it finished
            }
        }
    }
}
