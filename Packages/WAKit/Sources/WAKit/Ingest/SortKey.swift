/// `sortKey` packs `(timestamp, ingestSeq)` into one sortable Int64:
/// the unix-seconds timestamp in the high bits, the low 24 bits of `ingestSeq` as the tie-breaker.
/// 2^39 seconds of range, 16.7M ingests before the tie-breaker wraps (only matters within one second).
public enum SortKey {
    public static let seqBits: Int64 = 24
    static let seqMask: Int64 = (1 << seqBits) - 1

    public static func make(timestamp: Int64, seq: Int64) -> Int64 {
        (max(0, timestamp) << seqBits) | (seq & seqMask)
    }

    public static func timestamp(of sortKey: Int64) -> Int64 { sortKey >> seqBits }
}
