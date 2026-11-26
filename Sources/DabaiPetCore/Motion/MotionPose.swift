/// Translation in points and rotation in degrees around the body's anchor.
public struct MotionPose: Equatable, Sendable {
    public var offsetX: Double
    public var offsetY: Double
    public var rotationDegrees: Double
    public var scaleX: Double
    public var scaleY: Double

    public init(offsetX: Double = 0, offsetY: Double = 0, rotationDegrees: Double = 0,
                scaleX: Double = 1, scaleY: Double = 1) {
        self.offsetX = offsetX
        self.offsetY = offsetY
        self.rotationDegrees = rotationDegrees
        self.scaleX = scaleX
        self.scaleY = scaleY
    }
}
