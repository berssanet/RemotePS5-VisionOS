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
}
