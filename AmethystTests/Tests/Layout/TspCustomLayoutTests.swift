//
//  TspCustomLayoutTests.swift
//  AmethystTests
//
//  Created by Don Patterson on 10/17/26.
//  Copyright © 2026 Ian Ynda-Hummel. All rights reserved.
//

@testable import Amethyst
import Foundation
import Nimble
import Quick

/// The JavaScript Tertiary Split Partition layout bundled with the app, checked against the same cases as the native one.
class TspCustomLayoutTests: QuickSpec {
    override func spec() {
        afterEach {
            TestScreen.availableScreens = []
        }

        /// The bundled layout, found through the app's own Layouts folder.
        func bundledLayout() -> CustomLayout<TestWindow> {
            let fileURL = try! FileManager.default.layoutFile(key: "tsp-custom")
            expect(FileManager.default.fileExists(atPath: fileURL.path)).to(beTrue(), description: "tsp-custom.js is bundled with the app")
            return CustomLayout<TestWindow>(key: "tsp-custom", fileURL: fileURL)
        }

        /// A screen of the given size and `windowCount` windows ready to lay out on it.
        func fixture(width: CGFloat, height: CGFloat, windowCount: Int, origin: CGPoint = .zero) -> (screen: TestScreen, windows: [TestWindow], windowSet: WindowSet<TestWindow>) {
            let screen = TestScreen(frame: CGRect(origin: origin, size: CGSize(width: width, height: height)))
            TestScreen.availableScreens = [screen]

            let windows = (0..<windowCount).map { _ in TestWindow(element: nil)! }
            let layoutWindows = windows.map {
                LayoutWindow<TestWindow>(id: $0.id(), frame: $0.frame(), isFocused: false)
            }
            let windowSet = WindowSet<TestWindow>(
                windows: layoutWindows,
                isWindowWithIDActive: { _ in return true },
                isWindowWithIDFloating: { _ in return false },
                windowForID: { id in return windows.first { $0.id() == id } }
            )
            return (screen, windows, windowSet)
        }

        /// The expected frame of each window, keyed by window, in the order the windows were created.
        func expected(_ windows: [TestWindow], _ frames: [CGRect]) -> [String: CGRect] {
            return Dictionary(uniqueKeysWithValues: zip(windows.map { $0.id() }, frames))
        }

        describe("bundling") {
            it("is found among the available layouts under its own key") {
                let available = LayoutType<TestWindow>.availableLayoutStrings()
                expect(available.map { $0.key }).to(contain("tsp-custom"))
                expect(available.first { $0.key == "tsp-custom" }?.name).to(equal("Tertiary Split Partition (custom)"))
            }
        }

        describe("wide screen") {
            it("gives the first window the whole screen") {
                let (screen, windows, windowSet) = fixture(width: 2700, height: 1350, windowCount: 1)
                let frameAssignments = bundledLayout().frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 0, y: 0, width: 2700, height: 1350)
                ]))
            }

            it("gives the second window the left third") {
                let (screen, windows, windowSet) = fixture(width: 2700, height: 1350, windowCount: 2)
                let frameAssignments = bundledLayout().frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 900, y: 0, width: 1800, height: 1350),
                    CGRect(x: 0, y: 0, width: 900, height: 1350)
                ]))
            }

            it("gives the third window the right third") {
                let (screen, windows, windowSet) = fixture(width: 2700, height: 1350, windowCount: 3)
                let frameAssignments = bundledLayout().frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 900, y: 0, width: 900, height: 1350),
                    CGRect(x: 0, y: 0, width: 900, height: 1350),
                    CGRect(x: 1800, y: 0, width: 900, height: 1350)
                ]))
            }

            it("divides the second window's pane for the fourth window, in rows because that pane is tall, top first") {
                let (screen, windows, windowSet) = fixture(width: 2700, height: 1350, windowCount: 4)
                let frameAssignments = bundledLayout().frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 900, y: 0, width: 900, height: 1350),
                    CGRect(x: 0, y: 450, width: 900, height: 900),
                    CGRect(x: 1800, y: 0, width: 900, height: 1350),
                    CGRect(x: 0, y: 0, width: 900, height: 450)
                ]))
            }

            it("fills the side panes level by level, choosing each split's direction from the pane's shape") {
                let (screen, windows, windowSet) = fixture(width: 2700, height: 1350, windowCount: 8)
                let frameAssignments = bundledLayout().frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 900, y: 0, width: 900, height: 1350),
                    CGRect(x: 0, y: 450, width: 900, height: 450),
                    CGRect(x: 1800, y: 450, width: 900, height: 450),
                    CGRect(x: 300, y: 0, width: 600, height: 450),
                    CGRect(x: 1800, y: 0, width: 900, height: 450),
                    CGRect(x: 0, y: 900, width: 900, height: 450),
                    CGRect(x: 1800, y: 900, width: 900, height: 450),
                    CGRect(x: 0, y: 0, width: 300, height: 450)
                ]))
            }

            it("handles non-origin screens") {
                let (screen, windows, windowSet) = fixture(width: 2700, height: 1350, windowCount: 3, origin: CGPoint(x: 100, y: 200))
                let frameAssignments = bundledLayout().frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 1000, y: 200, width: 900, height: 1350),
                    CGRect(x: 100, y: 200, width: 900, height: 1350),
                    CGRect(x: 1900, y: 200, width: 900, height: 1350)
                ]))
            }
        }

        describe("tall screen") {
            it("puts the second window at the top and the third at the bottom") {
                let (screen, windows, windowSet) = fixture(width: 1350, height: 2700, windowCount: 3)
                let frameAssignments = bundledLayout().frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 0, y: 900, width: 1350, height: 900),
                    CGRect(x: 0, y: 0, width: 1350, height: 900),
                    CGRect(x: 0, y: 1800, width: 1350, height: 900)
                ]))
            }

            it("divides a wide side pane into columns") {
                let (screen, windows, windowSet) = fixture(width: 1350, height: 2700, windowCount: 4)
                let frameAssignments = bundledLayout().frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 0, y: 900, width: 1350, height: 900),
                    CGRect(x: 450, y: 0, width: 900, height: 900),
                    CGRect(x: 0, y: 1800, width: 1350, height: 900),
                    CGRect(x: 0, y: 0, width: 450, height: 900)
                ]))
            }
        }

        describe("square screen") {
            it("divides into rows") {
                let (screen, windows, windowSet) = fixture(width: 2700, height: 2700, windowCount: 2)
                let frameAssignments = bundledLayout().frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 0, y: 900, width: 2700, height: 1800),
                    CGRect(x: 0, y: 0, width: 2700, height: 900)
                ]))
            }
        }

        describe("main pane count") {
            it("stacks main windows across the split and moves the rest outward") {
                let (screen, windows, windowSet) = fixture(width: 2700, height: 1350, windowCount: 4)
                let layout = bundledLayout()

                layout.increaseMainPaneCount()
                var frameAssignments = layout.frameAssignments(windowSet, on: screen)!
                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 900, y: 0, width: 900, height: 675),
                    CGRect(x: 900, y: 675, width: 900, height: 675),
                    CGRect(x: 0, y: 0, width: 900, height: 1350),
                    CGRect(x: 1800, y: 0, width: 900, height: 1350)
                ]))

                layout.increaseMainPaneCount()
                frameAssignments = layout.frameAssignments(windowSet, on: screen)!
                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 900, y: 0, width: 1800, height: 450),
                    CGRect(x: 900, y: 450, width: 1800, height: 450),
                    CGRect(x: 900, y: 900, width: 1800, height: 450),
                    CGRect(x: 0, y: 0, width: 900, height: 1350)
                ]))

                layout.decreaseMainPaneCount()
                layout.decreaseMainPaneCount()
                layout.decreaseMainPaneCount()
                frameAssignments = layout.frameAssignments(windowSet, on: screen)!
                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 900, y: 0, width: 900, height: 1350),
                    CGRect(x: 0, y: 450, width: 900, height: 900),
                    CGRect(x: 1800, y: 0, width: 900, height: 1350),
                    CGRect(x: 0, y: 0, width: 900, height: 450)
                ]))
            }

            it("places main windows side by side on a tall screen") {
                let (screen, windows, windowSet) = fixture(width: 1350, height: 2700, windowCount: 3)
                let layout = bundledLayout()
                layout.increaseMainPaneCount()

                let frameAssignments = layout.frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 0, y: 900, width: 675, height: 1800),
                    CGRect(x: 675, y: 900, width: 675, height: 1800),
                    CGRect(x: 0, y: 0, width: 1350, height: 900)
                ]))
            }
        }

        describe("main pane ratio") {
            it("changes the main pane's share and leaves the side panes divided into thirds") {
                let (screen, windows, windowSet) = fixture(width: 2700, height: 1350, windowCount: 7)
                let layout = bundledLayout()

                _ = layout.frameAssignments(windowSet, on: screen)
                layout.recommendMainPaneRatio(0.5)

                let frameAssignments = layout.frameAssignments(windowSet, on: screen)!

                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 675, y: 0, width: 1350, height: 1350),
                    CGRect(x: 0, y: 450, width: 675, height: 450),
                    CGRect(x: 2025, y: 450, width: 675, height: 450),
                    CGRect(x: 0, y: 0, width: 675, height: 450),
                    CGRect(x: 2025, y: 0, width: 675, height: 450),
                    CGRect(x: 0, y: 900, width: 675, height: 450),
                    CGRect(x: 2025, y: 900, width: 675, height: 450)
                ]))
            }

            it("reads a recommendation as the share of the screen the main pane should show") {
                let layout = bundledLayout()

                let two = fixture(width: 2700, height: 1350, windowCount: 2)
                _ = layout.frameAssignments(two.windowSet, on: two.screen)
                layout.recommendMainPaneRatio(0.75)

                var frameAssignments = layout.frameAssignments(two.windowSet, on: two.screen)!
                frameAssignments.verify(frames: expected(two.windows, [
                    CGRect(x: 675, y: 0, width: 2025, height: 1350),
                    CGRect(x: 0, y: 0, width: 675, height: 1350)
                ]))

                let three = fixture(width: 2700, height: 1350, windowCount: 3)
                _ = layout.frameAssignments(three.windowSet, on: three.screen)
                layout.recommendMainPaneRatio(1.0 / 3.0)

                frameAssignments = layout.frameAssignments(three.windowSet, on: three.screen)!
                frameAssignments.verify(frames: expected(three.windows, [
                    CGRect(x: 900, y: 0, width: 900, height: 1350),
                    CGRect(x: 0, y: 0, width: 900, height: 1350),
                    CGRect(x: 1800, y: 0, width: 900, height: 1350)
                ]))
            }

            it("keeps a window at the size a drag left it in either orientation") {
                let defaults = UserDefaults.standard
                let savedMargins = defaults.object(forKey: "window-margins")
                defaults.set(false, forKey: "window-margins")
                defer { defaults.set(savedMargins, forKey: "window-margins") }

                let wide = fixture(width: 2700, height: 1350, windowCount: 2)
                let wideLayout = bundledLayout()
                var assignments = wideLayout.frameAssignments(wide.windowSet, on: wide.screen)!

                let mainAssignment = assignments.forWindows(wide.windows[..<1])[0].frameAssignment
                expect(mainAssignment.resizeRules.unconstrainedDimension).to(equal(.horizontal))
                let draggedMain = CGRect(x: 675, y: 0, width: 2025, height: 1350)
                wideLayout.recommendMainPaneRatio(mainAssignment.impliedMainPaneRatio(windowFrame: draggedMain))

                assignments = wideLayout.frameAssignments(wide.windowSet, on: wide.screen)!
                assignments.forWindows(wide.windows[..<1]).verify(frames: [draggedMain])

                let sideAssignment = assignments.forWindows(wide.windows[1...])[0].frameAssignment
                let draggedSide = CGRect(x: 0, y: 0, width: 900, height: 1350)
                wideLayout.recommendMainPaneRatio(sideAssignment.impliedMainPaneRatio(windowFrame: draggedSide))

                assignments = wideLayout.frameAssignments(wide.windowSet, on: wide.screen)!
                assignments.forWindows(wide.windows[1...]).verify(frames: [draggedSide])

                let tall = fixture(width: 1350, height: 2700, windowCount: 2)
                let tallLayout = bundledLayout()
                assignments = tallLayout.frameAssignments(tall.windowSet, on: tall.screen)!

                let tallMainAssignment = assignments.forWindows(tall.windows[..<1])[0].frameAssignment
                expect(tallMainAssignment.resizeRules.unconstrainedDimension).to(equal(.vertical))
                let draggedTallMain = CGRect(x: 0, y: 675, width: 1350, height: 2025)
                tallLayout.recommendMainPaneRatio(tallMainAssignment.impliedMainPaneRatio(windowFrame: draggedTallMain))

                assignments = tallLayout.frameAssignments(tall.windowSet, on: tall.screen)!
                assignments.forWindows(tall.windows[..<1]).verify(frames: [draggedTallMain])
            }

            it("moves a side window's share with the main pane when both sides are occupied") {
                let defaults = UserDefaults.standard
                let savedMargins = defaults.object(forKey: "window-margins")
                defaults.set(false, forKey: "window-margins")
                defer { defaults.set(savedMargins, forKey: "window-margins") }

                let (screen, windows, windowSet) = fixture(width: 2700, height: 1350, windowCount: 3)
                let layout = bundledLayout()
                var assignments = layout.frameAssignments(windowSet, on: screen)!

                // Dragging the left window out to 1000 points leaves 700 points for the main pane.
                let sideAssignment = assignments.forWindows(windows[1..<2])[0].frameAssignment
                let draggedSide = CGRect(x: 0, y: 0, width: 1000, height: 1350)
                layout.recommendMainPaneRatio(sideAssignment.impliedMainPaneRatio(windowFrame: draggedSide))

                assignments = layout.frameAssignments(windowSet, on: screen)!
                assignments.verify(frames: expected(windows, [
                    CGRect(x: 1000, y: 0, width: 700, height: 1350),
                    CGRect(x: 0, y: 0, width: 1000, height: 1350),
                    CGRect(x: 1700, y: 0, width: 1000, height: 1350)
                ]))
            }

            it("moves by the resize step from the hotkeys regardless of window count") {
                let defaults = UserDefaults.standard
                let savedStep = defaults.object(forKey: "window-resize-step")
                defaults.set(10, forKey: "window-resize-step")
                defer { defaults.set(savedStep, forKey: "window-resize-step") }

                let (screen, windows, windowSet) = fixture(width: 2700, height: 1350, windowCount: 2)
                let layout = bundledLayout()
                _ = layout.frameAssignments(windowSet, on: screen)

                // From a third the step of a tenth takes the main pane's share to 13/30 of the screen; with one side occupied it shows that plus half the rest.
                layout.expandMainPane()
                var frameAssignments = layout.frameAssignments(windowSet, on: screen)!
                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 765, y: 0, width: 1935, height: 1350),
                    CGRect(x: 0, y: 0, width: 765, height: 1350)
                ]))

                layout.shrinkMainPane()
                layout.shrinkMainPane()
                frameAssignments = layout.frameAssignments(windowSet, on: screen)!
                frameAssignments.verify(frames: expected(windows, [
                    CGRect(x: 1035, y: 0, width: 1665, height: 1350),
                    CGRect(x: 0, y: 0, width: 1035, height: 1350)
                ]))
            }
        }
    }
}
