import Foundation

/// Passive statistics of this client's sent transactions. No probe packets or input retries.
public struct NetTransactionStatistics: Sendable, Encodable, Equatable {
    public private(set) var sent: UInt64 = 0
    public private(set) var acknowledged: UInt64 = 0
    public private(set) var timeouts: UInt64 = 0
    public private(set) var receiveFailures: UInt64 = 0
    public private(set) var ignoredResponses: UInt64 = 0
    public private(set) var bytesSent: UInt64 = 0
    public private(set) var minimumMilliseconds: Double?
    public private(set) var maximumMilliseconds: Double?
    public private(set) var meanMilliseconds: Double?
    public private(set) var standardDeviationMilliseconds: Double?
    private var squaredDeviation = 0.0

    private enum CodingKeys: String, CodingKey {
        case sent, acknowledged, timeouts, receiveFailures, ignoredResponses, bytesSent
        case minimumMilliseconds, maximumMilliseconds, meanMilliseconds, standardDeviationMilliseconds
    }
    public init() {}
    mutating func didSend(bytes: Int) { sent += 1; bytesSent += UInt64(bytes) }
    mutating func didAcknowledge(milliseconds: Double, ignored: Int) {
        acknowledged += 1; ignoredResponses += UInt64(ignored)
        minimumMilliseconds = min(minimumMilliseconds ?? milliseconds, milliseconds)
        maximumMilliseconds = max(maximumMilliseconds ?? milliseconds, milliseconds)
        let oldMean = meanMilliseconds ?? 0
        let mean = oldMean + (milliseconds - oldMean) / Double(acknowledged)
        squaredDeviation += (milliseconds - oldMean) * (milliseconds - mean)
        meanMilliseconds = mean
        standardDeviationMilliseconds = sqrt(max(0, squaredDeviation / Double(acknowledged)))
    }
    mutating func didFail(_ error: Error, ignored: Int) {
        ignoredResponses += UInt64(ignored)
        if case KMError.timeout = error { timeouts += 1 } else { receiveFailures += 1 }
    }
}
