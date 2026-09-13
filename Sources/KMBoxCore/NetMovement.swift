import Foundation

/// A relative endpoint and the duration requested from the device, not measured motion time.
public struct NetTimedMovement: Sendable, Equatable {
    public let x: Int32
    public let y: Int32
    public let milliseconds: UInt32

    public init(x: Int32, y: Int32, milliseconds: Int) throws {
        try validateMouseCoordinates(x, y)
        // Bound the serialized transaction's wait so disconnect/release can still finish promptly.
        guard (1...10_000).contains(milliseconds) else { throw KMError.invalid("本程序定时移动支持 1–10000 毫秒。") }
        self.x = x; self.y = y; self.milliseconds = UInt32(milliseconds)
    }
}

/// Control points relative to the same origin as the endpoint, in the official Net packet order.
public struct NetBezierControls: Sendable, Equatable {
    public let x1: Int32
    public let y1: Int32
    public let x2: Int32
    public let y2: Int32
    public init(x1: Int32, y1: Int32, x2: Int32, y2: Int32) throws {
        try validateMouseCoordinates(x1, y1); try validateMouseCoordinates(x2, y2)
        self.x1 = x1; self.y1 = y1; self.x2 = x2; self.y2 = y2
    }
}

func validateMouseCoordinates(_ x: Int32, _ y: Int32) throws {
    guard (-32768...32767).contains(x), (-32768...32767).contains(y) else {
        throw KMError.invalid("位移与控制点坐标范围为 -32768…32767。")
    }
}
