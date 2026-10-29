import Foundation
import Testing
import WebbyCore
@testable import WebbySkinArchive

// MARK: - Staging

final class ArchiveMediaStage {
    let root: URL
    let staged: StagedSkinArchive

    init(
        files: [String: Data],
        warnings: [SkinDiagnostic] = []
    ) throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "WebbySkinArchiveMediaTests-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)

        let paths = files.keys.sorted {
            Data($0.utf8).lexicographicallyPrecedes(Data($1.utf8))
        }
        for path in paths {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try files[path]!.write(to: url)
        }

        let entries = paths.map { path in
            let data = files[path]!
            return SkinArchivePreflightEntry(
                rawPath: path,
                path: path,
                compressionMethod: 0,
                compressedSize: UInt32(data.count),
                uncompressedSize: UInt32(data.count),
                crc32: 0,
                localHeaderOffset: 0
            )
        }
        staged = StagedSkinArchive(root: root, entries: entries, warnings: warnings)
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }
}

// MARK: - Manifests

func archiveManifest(extra: String = "") -> Data {
    Data("""
    {
      "formatVersion": 1,
      "id": "io.example.archive",
      "name": "Archive",
      "author": "Test",
      "version": "1.0.0"\(extra)
    }
    """.utf8)
}

let archiveSurfaceGroup = """
,
  "surface": {
    "image": {
      "element": "note-body",
      "insets": { "top": 1, "left": 1, "bottom": 1, "right": 1 }
    }
  }
"""

let archiveSoundsGroup = """
,
  "sounds": { "volume": 0.5 }
"""

// MARK: - PNG fixtures

let onePixelPNG = Data(base64Encoded: """
iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==
""")!

func pngWithRewrittenIHDR(
    width: UInt32,
    height: UInt32,
    from source: Data = onePixelPNG
) -> Data {
    var bytes = [UInt8](source)
    writeUInt32BE(width, at: 16, in: &bytes)
    writeUInt32BE(height, at: 20, in: &bytes)
    let crc = crc32(bytes[12..<29])
    writeUInt32BE(crc, at: 29, in: &bytes)
    return Data(bytes)
}

func headerOnlyPNG(width: UInt32, height: UInt32) -> Data {
    var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
    appendUInt32BE(13, to: &bytes)
    bytes.append(contentsOf: Array("IHDR".utf8))
    appendUInt32BE(width, to: &bytes)
    appendUInt32BE(height, to: &bytes)
    bytes.append(8)
    bytes.append(6)
    bytes.append(0)
    bytes.append(0)
    bytes.append(0)
    appendUInt32BE(crc32(bytes[12..<29]), to: &bytes)
    return Data(bytes)
}

// MARK: - Sound fixtures

func makePCMWAV(
    sampleRate: UInt32,
    channels: UInt16,
    bits: UInt16,
    frames: Int
) -> Data {
    let bytesPerFrame = Int(channels) * Int(bits) / 8
    let byteRate = sampleRate * UInt32(bytesPerFrame)
    let dataBytes = frames * bytesPerFrame

    var data = Data()
    appendASCII("RIFF", to: &data)
    appendUInt32LE(UInt32(36 + dataBytes), to: &data)
    appendASCII("WAVE", to: &data)
    appendASCII("fmt ", to: &data)
    appendUInt32LE(16, to: &data)
    appendUInt16LE(1, to: &data)
    appendUInt16LE(channels, to: &data)
    appendUInt32LE(sampleRate, to: &data)
    appendUInt32LE(byteRate, to: &data)
    appendUInt16LE(UInt16(bytesPerFrame), to: &data)
    appendUInt16LE(bits, to: &data)
    appendASCII("data", to: &data)
    appendUInt32LE(UInt32(dataBytes), to: &data)
    data.append(contentsOf: [UInt8](repeating: 0, count: dataBytes))
    return data
}

func makePCMAIFF(sampleRate: Double, frames: UInt32) -> Data {
    var comm = Data()
    appendUInt16BE(1, to: &comm)
    appendUInt32BE(frames, to: &comm)
    appendUInt16BE(16, to: &comm)
    appendExtended80(sampleRate, to: &comm)

    let audioBytes = Int(frames) * 2
    var ssnd = Data()
    appendUInt32BE(0, to: &ssnd)
    appendUInt32BE(0, to: &ssnd)
    ssnd.append(contentsOf: [UInt8](repeating: 0, count: audioBytes))

    var data = Data()
    appendASCII("FORM", to: &data)
    appendUInt32BE(UInt32(4 + 8 + comm.count + 8 + ssnd.count), to: &data)
    appendASCII("AIFF", to: &data)
    appendASCII("COMM", to: &data)
    appendUInt32BE(UInt32(comm.count), to: &data)
    data.append(comm)
    appendASCII("SSND", to: &data)
    appendUInt32BE(UInt32(ssnd.count), to: &data)
    data.append(ssnd)
    return data
}

func makeCAF(
    sampleRate: Double,
    formatID: String = "lpcm",
    formatFlags: UInt32 = 0,
    bytesPerPacket: UInt32,
    framesPerPacket: UInt32,
    packetCount: Int,
    bitsPerChannel: UInt32 = 16
) -> Data {
    var desc = Data()
    appendUInt64BE(sampleRate.bitPattern, to: &desc)
    appendASCII(formatID, to: &desc)
    appendUInt32BE(formatFlags, to: &desc)
    appendUInt32BE(bytesPerPacket, to: &desc)
    appendUInt32BE(framesPerPacket, to: &desc)
    appendUInt32BE(1, to: &desc)
    appendUInt32BE(bitsPerChannel, to: &desc)

    let audioBytes = packetCount * Int(bytesPerPacket)
    let dataBytes = audioBytes + 4

    var data = Data()
    appendASCII("caff", to: &data)
    appendUInt16BE(1, to: &data)
    appendUInt16BE(0, to: &data)
    appendASCII("desc", to: &data)
    appendUInt64BE(UInt64(desc.count), to: &data)
    data.append(desc)
    appendASCII("data", to: &data)
    appendUInt64BE(UInt64(dataBytes), to: &data)
    appendUInt32BE(0, to: &data)
    data.append(contentsOf: [UInt8](repeating: 0, count: audioBytes))
    return data
}

// MARK: - Byte helpers

func appendASCII(_ string: String, to data: inout Data) {
    data.append(contentsOf: Array(string.utf8))
}

func appendUInt16LE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
}

func appendUInt16BE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

func appendUInt32LE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8(value & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 24) & 0xFF))
}

func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(contentsOf: [
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF),
    ])
}

func appendUInt64BE(_ value: UInt64, to data: inout Data) {
    for shift in stride(from: 56, through: 0, by: -8) {
        data.append(UInt8((value >> UInt64(shift)) & 0xFF))
    }
}

func appendExtended80(_ value: Double, to data: inout Data) {
    guard value != 0 else {
        data.append(contentsOf: [UInt8](repeating: 0, count: 10))
        return
    }

    let exponent = Int(floor(log2(value)))
    let mantissa = value / pow(2, Double(exponent))
    let biasedExponent = exponent + 16_383
    let mantissaBits = UInt64((mantissa * pow(2, 63)).rounded())

    appendUInt16BE(UInt16(biasedExponent), to: &data)
    appendUInt64BE(mantissaBits, to: &data)
}

private func writeUInt32BE(_ value: UInt32, at offset: Int, in bytes: inout [UInt8]) {
    bytes[offset] = UInt8((value >> 24) & 0xFF)
    bytes[offset + 1] = UInt8((value >> 16) & 0xFF)
    bytes[offset + 2] = UInt8((value >> 8) & 0xFF)
    bytes[offset + 3] = UInt8(value & 0xFF)
}

private func crc32(_ bytes: ArraySlice<UInt8>) -> UInt32 {
    var crc: UInt32 = 0xFFFF_FFFF
    for byte in bytes {
        crc ^= UInt32(byte)
        for _ in 0..<8 {
            if crc & 1 != 0 {
                crc = (crc >> 1) ^ 0xEDB8_8320
            } else {
                crc >>= 1
            }
        }
    }
    return crc ^ 0xFFFF_FFFF
}
