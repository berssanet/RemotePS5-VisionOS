//
//  ControllerInput.swift
//  VisionRemotePS5
//
//  Controller input snapshot shared between GameControllerManager (producer)
//  and StreamingService.onInputReady (consumer). Extracted from the removed
//  StreamingSession.swift so the 120Hz input contract keeps a single source
//  of truth for the PlayStation button layout.
//

import Foundation

struct ControllerInput {
    var leftStickX: Float = 0
    var leftStickY: Float = 0
    var rightStickX: Float = 0
    var rightStickY: Float = 0
    var leftTrigger: Float = 0
    var rightTrigger: Float = 0
    var buttons: UInt32 = 0

    // Button bit masks (PlayStation layout)
    static let buttonCross: UInt32    = 1 << 0
    static let buttonCircle: UInt32   = 1 << 1
    static let buttonSquare: UInt32   = 1 << 2
    static let buttonTriangle: UInt32 = 1 << 3
    static let buttonL1: UInt32       = 1 << 4
    static let buttonR1: UInt32       = 1 << 5
    static let buttonL2: UInt32       = 1 << 6
    static let buttonR2: UInt32       = 1 << 7
    static let buttonShare: UInt32    = 1 << 8
    static let buttonOptions: UInt32  = 1 << 9
    static let buttonL3: UInt32       = 1 << 10
    static let buttonR3: UInt32       = 1 << 11
    static let buttonPS: UInt32       = 1 << 12
    static let buttonTouchpad: UInt32 = 1 << 13
    static let dpadUp: UInt32         = 1 << 14
    static let dpadDown: UInt32       = 1 << 15
    static let dpadLeft: UInt32       = 1 << 16
    static let dpadRight: UInt32      = 1 << 17
}
