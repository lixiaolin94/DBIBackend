/// 一个文件里已经发给 Switch 的区间（重叠、相邻的会合并）。
/// DBI 会先读文件头和文件尾，也会重读同一段，所以进度不能按"读到的最远位置"或累计字节算。
struct Coverage {
    private(set) var ranges: [Range<UInt64>] = []
    private(set) var total: UInt64 = 0

    mutating func insert(_ range: Range<UInt64>) {
        guard !range.isEmpty else { return }
        var merged = range
        var kept: [Range<UInt64>] = []
        kept.reserveCapacity(ranges.count + 1)
        for r in ranges {
            if r.upperBound < merged.lowerBound || r.lowerBound > merged.upperBound {
                kept.append(r)
            } else {
                merged = min(r.lowerBound, merged.lowerBound) ..< max(r.upperBound, merged.upperBound)
            }
        }
        let index = kept.firstIndex { $0.lowerBound > merged.lowerBound } ?? kept.count
        kept.insert(merged, at: index)
        ranges = kept
        total = kept.reduce(0) { $0 + UInt64($1.count) }
    }
}
