import Foundation
import Metal

struct CubeLUT {
    let dimension: Int
    let domainMin: SIMD3<Float>
    let domainMax: SIMD3<Float>
    let colors: [SIMD3<Float>]

    enum ParseError: LocalizedError {
        case missingSize, invalidSize, wrongEntryCount(expected: Int, actual: Int), invalidNumber(String)
        var errorDescription: String? {
            switch self {
            case .missingSize: return "Missing LUT_3D_SIZE"
            case .invalidSize: return "Invalid LUT_3D_SIZE"
            case let .wrongEntryCount(expected, actual): return "Expected \(expected) RGB entries, found \(actual)"
            case let .invalidNumber(line): return "Invalid LUT row: \(line)"
            }
        }
    }

    static func parse(url: URL) throws -> Self {
        let text = try String(contentsOf: url, encoding: .utf8)
        var dimension: Int?
        var domainMin = SIMD3<Float>(repeating: 0)
        var domainMax = SIMD3<Float>(repeating: 1)
        var colors: [SIMD3<Float>] = []

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.split(separator: "#", maxSplits: 1).first.map(String.init)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !line.isEmpty, !line.hasPrefix("TITLE") else { continue }
            let columns = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard let head = columns.first?.uppercased() else { continue }
            if head == "LUT_3D_SIZE" { dimension = columns.dropFirst().first.flatMap { Int($0) }; continue }
            if head == "DOMAIN_MIN" || head == "DOMAIN_MAX" {
                guard columns.count == 4, let r = Float(columns[1]), let g = Float(columns[2]), let b = Float(columns[3]) else { throw ParseError.invalidNumber(line) }
                if head == "DOMAIN_MIN" { domainMin = [r, g, b] } else { domainMax = [r, g, b] }
                continue
            }
            guard columns.count == 3, let r = Float(columns[0]), let g = Float(columns[1]), let b = Float(columns[2]) else { throw ParseError.invalidNumber(line) }
            colors.append([r, g, b])
        }
        guard let dimension, dimension > 1 else { throw dimension == nil ? ParseError.missingSize : ParseError.invalidSize }
        let expected = dimension * dimension * dimension
        guard colors.count == expected else { throw ParseError.wrongEntryCount(expected: expected, actual: colors.count) }
        return Self(dimension: dimension, domainMin: domainMin, domainMax: domainMax, colors: colors)
    }

    func makeTexture(on device: MTLDevice) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor()
        descriptor.textureType = .type3D
        descriptor.pixelFormat = .rgba16Float
        descriptor.width = dimension
        descriptor.height = dimension
        descriptor.depth = dimension
        descriptor.usage = .shaderRead
        guard let texture = device.makeTexture(descriptor: descriptor) else { return nil }
        let texels = colors.flatMap { color in [Float16(color.x).bitPattern, Float16(color.y).bitPattern, Float16(color.z).bitPattern, Float16(1).bitPattern] }
        texels.withUnsafeBytes { bytes in
            texture.replace(region: MTLRegionMake3D(0, 0, 0, dimension, dimension, dimension), mipmapLevel: 0, slice: 0, withBytes: bytes.baseAddress!, bytesPerRow: dimension * 8, bytesPerImage: dimension * dimension * 8)
        }
        return texture
    }
}
