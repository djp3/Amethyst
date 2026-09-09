//
//  TestWindow.swift
//  AmethystTests
//
//  Created by Ian Ynda-Hummel on 9/14/19.
//  Copyright © 2019 Ian Ynda-Hummel. All rights reserved.
//

@testable import Amethyst
import Foundation
import Silica

final class TestWindow: WindowType {
    typealias Screen = TestScreen
    typealias WindowID = String

    static var focused: TestWindow?

    private let element: SIAccessibilityElement?
    private let cgWindowID = CGWindowID(Int.random(in: 1...1000))
    private let uuid = UUID().uuidString
    private var _frame: CGRect = .zero
    var isFocusedValue = false
    var isResizableValue = true

    /// Every frame applied through `setFrame` or `setAnimationFrame`, in order.
    private(set) var frameHistory: [CGRect] = []

    static func currentlyFocused() -> Self? {
        return (focused as? Self)
    }

    required init?(element: SIAccessibilityElement?) {
        self.element = element
    }

    func id() -> WindowID {
        return uuid
    }

    func cgID() -> CGWindowID {
        return cgWindowID
    }

    func frame() -> CGRect {
        return _frame
    }

    func screen() -> Screen? {
        return nil
    }

    func setFrame(_ frame: CGRect, withThreshold threshold: CGSize) {
        _frame = CGRect(origin: constrained(frame.origin), size: constrained(frame.size))
        frameHistory.append(_frame)
    }

    func isResizable() -> Bool {
        return isResizableValue
    }

    /// Simulates a slow application: how long each animation frame write should block.
    var animationFrameDelay: TimeInterval = 0

    /// Lets a test react to each animation frame write, for example to cancel an operation at a precise moment.
    var onAnimationFrame: ((CGRect) -> Void)?

    /// Simulates an application that refuses to grow beyond a certain size, like System Settings.
    var maximumSize: CGSize?

    /// Simulates a window kept below a certain y, the way macOS keeps windows below the menu bar.
    var minimumY: CGFloat?

    /// Simulates an application that refuses to shrink below a certain size, like Mail.
    var minimumSize: CGSize?

    private func constrained(_ size: CGSize) -> CGSize {
        var result = size
        if let maximumSize = maximumSize {
            result = CGSize(width: min(result.width, maximumSize.width), height: min(result.height, maximumSize.height))
        }
        if let minimumSize = minimumSize {
            result = CGSize(width: max(result.width, minimumSize.width), height: max(result.height, minimumSize.height))
        }
        return result
    }

    private func constrained(_ origin: CGPoint) -> CGPoint {
        guard let minimumY = minimumY else {
            return origin
        }
        return CGPoint(x: origin.x, y: max(origin.y, minimumY))
    }

    func setAnimationFrame(_ frame: CGRect, includingSize: Bool) {
        if animationFrameDelay > 0 {
            Thread.sleep(forTimeInterval: animationFrameDelay)
        }
        _frame = CGRect(origin: constrained(frame.origin), size: includingSize ? constrained(frame.size) : _frame.size)
        frameHistory.append(_frame)
        onAnimationFrame?(_frame)
    }

    func clearFrameHistory() {
        frameHistory.removeAll()
    }

    func isFocused() -> Bool {
        return isFocusedValue
    }

    func pid() -> pid_t {
        return pid_t(1234)
    }

    func title() -> String? {
        return nil
    }

    func shouldBeManaged() -> Bool {
        return true
    }

    func shouldFloat() -> Bool {
        return false
    }

    func isActive() -> Bool {
        return true
    }

    func focus() -> Bool {
        return false
    }

    func minimize() -> Bool {
      return false
    }

    func moveScaled(to screen: Screen) {

    }

    func isOnScreen() -> Bool {
        return true
    }

    func move(toSpace space: UInt) {

    }

    func move(toSpaceAtIndex space: UInt) {

    }

    func move(toSpace spaceID: CGSSpaceID) {

    }

    static func == (lhs: TestWindow, rhs: TestWindow) -> Bool {
        return lhs.id() == rhs.id()
    }
}
