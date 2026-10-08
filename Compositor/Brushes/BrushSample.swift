import AppKit

/// One stylus / pointer sample threaded from the event layer down to the stroke.
/// Pressure, tilt and rotation are only meaningful for genuine tablet events
/// (`subtype == .tabletPoint`); mouse and trackpad input report full pressure.
nonisolated struct BrushSample: Sendable, Equatable {
    var point: CGPoint
    /// 0…1 stylus pressure (1 = full). A trackpad's Force Touch pressure is
    /// deliberately ignored so it can't masquerade as pen pressure.
    var pressure: CGFloat
    var isTablet: Bool
    /// Tilt along each axis, −1…1 (only some Wacom models report it).
    var tilt: CGPoint
    /// Stylus rotation in degrees (only a few pens report it).
    var rotation: CGFloat
    var timestamp: TimeInterval

    init(point: CGPoint, pressure: CGFloat = 1, isTablet: Bool = false,
         tilt: CGPoint = .zero, rotation: CGFloat = 0, timestamp: TimeInterval = 0) {
        self.point = point
        self.pressure = pressure.isFinite ? min(1, max(0, pressure)) : 1
        self.isTablet = isTablet
        self.tilt = tilt
        self.rotation = rotation
        self.timestamp = timestamp
    }

    /// Builds a sample from a mouse event and a document-space point, keeping
    /// only the tablet data a real pen provides.
    init(event: NSEvent, point: CGPoint) {
        let tablet = event.subtype == .tabletPoint
        self.init(point: point,
                  pressure: tablet ? CGFloat(event.pressure) : 1,
                  isTablet: tablet,
                  tilt: tablet ? event.tilt : .zero,
                  rotation: tablet ? CGFloat(event.rotation) : 0,
                  timestamp: event.timestamp)
    }
}
