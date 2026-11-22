import FeatureLiveTVCore

/// Records the first begin/done pair of `body` in the DEBUG tvOS open trace; a plain call everywhere else.
@inline(__always)
func guideOpenTraced<T>(_ name: String, _ body: () -> T) -> T {
    #if DEBUG && os(tvOS)
    LiveTVOpenTrace.mark("\(name).begin")
    defer { LiveTVOpenTrace.mark("\(name).done") }
    #endif
    return body()
}
