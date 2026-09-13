import Foundation

/// Timestamps are taken by the Mac immediately after recvfrom, not by the device or UI timer.
public struct NetMonitorRecord: Sendable, Encodable {
    public let kind = "datagram"
    public let sessionID: UUID
    public let sequence: UInt64
    public let receivedAtUnixSeconds: Double
    public let monotonicNanoseconds: UInt64
    public let sourceIPv4: String
    public let sourcePort: UInt16
    public let listenPort: UInt16
    public let rawHex: String
    public let frame: NetMonitorFrame?
    public let decodeError: String?

    init(data: Data, sessionID: UUID, sequence: UInt64, receivedAt: Date, monotonicNanoseconds: UInt64,
         sourceIPv4: String, sourcePort: UInt16, listenPort: UInt16) {
        self.sessionID = sessionID; self.sequence = sequence
        receivedAtUnixSeconds = receivedAt.timeIntervalSince1970
        self.monotonicNanoseconds = monotonicNanoseconds
        self.sourceIPv4 = sourceIPv4; self.sourcePort = sourcePort; self.listenPort = listenPort
        rawHex = data.hexadecimal
        do { frame = try NetMonitorFrame(data: data); decodeError = nil }
        catch { frame = nil; decodeError = error.localizedDescription }
    }
}

/// GUI retains a bounded snapshot; CLI can stream every received batch straight to disk.
public struct NetMonitorCapture: Sendable {
    public private(set) var records: [NetMonitorRecord] = []
    public private(set) var discardedRecords: UInt64 = 0
    private var rawBytes = 0
    public static let maximumRecords = 10_000
    public static let maximumRawBytes = 8 * 1024 * 1024
    public init() {}

    public mutating func append(_ batch: [NetMonitorRecord]) {
        records.append(contentsOf: batch)
        rawBytes += batch.reduce(0) { $0 + $1.rawHex.utf8.count / 2 }
        var removed = 0
        while records.count - removed > Self.maximumRecords || rawBytes > Self.maximumRawBytes {
            rawBytes -= records[removed].rawHex.utf8.count / 2; removed += 1
        }
        if removed > 0 { records.removeFirst(removed); discardedRecords += UInt64(removed) }
    }

    public func jsonLines() throws -> Data {
        try NetMonitorJSONL.header(retainedRecords: records.count, discardedRecords: discardedRecords)
            + NetMonitorJSONL.records(records)
    }
}

public enum NetMonitorJSONL {
    public static func header(retainedRecords: Int? = nil, discardedRecords: UInt64? = nil) throws -> Data {
        struct Header: Encodable {
            let kind = "capture"
            let schemaVersion = 1
            let clock = "Mac recvfrom time; not device time or HID execution time"
            let timestamps = "receivedAtUnixSeconds: wall clock seconds; monotonicNanoseconds: host uptime nanoseconds"
            let retainedRecords: Int?
            let discardedRecords: UInt64?
            let mode: String
        }
        return try line(Header(retainedRecords: retainedRecords, discardedRecords: discardedRecords,
                               mode: retainedRecords == nil ? "live-stream" : "retained-snapshot"))
    }
    public static func records(_ records: [NetMonitorRecord]) throws -> Data {
        var data = Data()
        for record in records { data.append(try line(record)) }
        return data
    }
    private static func line<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value) + Data([10])
    }
}
