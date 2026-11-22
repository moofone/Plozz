import Foundation
import zlib

/// Bounded gzip decoding for small public data exports.
///
/// Uses the system zlib, which is available on every Plozz platform. The output is
/// capped so a corrupt or hostile archive cannot grow without limit.
enum GzipDecoder {
    /// The expanded bytes of `data`, or `nil` when it is not a valid gzip stream
    /// or would expand past `maximumBytes`.
    static func inflate(_ data: Data, maximumBytes: Int) -> Data? {
        guard data.starts(with: [0x1f, 0x8b]), maximumBytes > 0 else { return nil }
        var stream = z_stream()
        guard inflateInit2_(&stream, 15 + 16, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)) == Z_OK else {
            return nil
        }
        defer { inflateEnd(&stream) }
        var output = Data()
        let chunkSize = 64 * 1_024
        var chunk = [UInt8](repeating: 0, count: chunkSize)
        return data.withUnsafeBytes { (input: UnsafeRawBufferPointer) -> Data? in
            guard let base = input.baseAddress else { return nil }
            stream.next_in = UnsafeMutablePointer(mutating: base.assumingMemoryBound(to: Bytef.self))
            stream.avail_in = uInt(input.count)
            while true {
                let status: Int32 = chunk.withUnsafeMutableBytes { buffer in
                    stream.next_out = buffer.baseAddress!.assumingMemoryBound(to: Bytef.self)
                    stream.avail_out = uInt(chunkSize)
                    return zlib.inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunkSize - Int(stream.avail_out)
                if produced > 0 {
                    guard output.count + produced <= maximumBytes else { return nil }
                    output.append(contentsOf: chunk.prefix(produced))
                }
                switch status {
                case Z_STREAM_END: return output
                case Z_OK:
                    // A truncated archive stops making progress before Z_STREAM_END.
                    if produced == 0, stream.avail_in == 0 { return nil }
                default: return nil
                }
            }
        }
    }
}
