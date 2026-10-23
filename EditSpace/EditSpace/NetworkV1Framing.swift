import Foundation

public enum NetworkV1FrameError: Error, Equatable, Sendable {
    case zeroLength
    case frameTooLarge(Int)
    case invalidUTF8
    case invalidJSON
    case nonObjectRoot
    case duplicateJSONKey(String)
}

public struct NetworkV1FrameCodec: Sendable {
    public static let maximumPayloadSize = 16_777_216

    private var buffer = Data()
    private var expectedLength: Int?

    public init() {}

    public static func encode(payload: Data) throws -> Data {
        guard !payload.isEmpty else { throw NetworkV1FrameError.zeroLength }
        guard payload.count <= maximumPayloadSize else { throw NetworkV1FrameError.frameTooLarge(payload.count) }
        var length = UInt32(payload.count).bigEndian
        var result = Data(bytes: &length, count: MemoryLayout<UInt32>.size)
        result.append(payload)
        return result
    }

    public static func encode(message: NetworkV1Message) throws -> Data {
        try encode(payload: NetworkV1MessageCodec.encode(message))
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var frames: [Data] = []
        while true {
            if expectedLength == nil {
                guard buffer.count >= 4 else { break }
                let length = buffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                buffer.removeFirst(4)
                guard length > 0 else { throw NetworkV1FrameError.zeroLength }
                guard length <= UInt32(Self.maximumPayloadSize) else {
                    throw NetworkV1FrameError.frameTooLarge(Int(length))
                }
                expectedLength = Int(length)
            }
            guard let expectedLength, buffer.count >= expectedLength else { break }
            let payload = Data(buffer.prefix(expectedLength))
            buffer.removeFirst(expectedLength)
            self.expectedLength = nil
            try Self.validateJSONPayload(payload)
            frames.append(payload)
        }
        return frames
    }

    public var hasPartialFrame: Bool {
        expectedLength != nil || !buffer.isEmpty
    }

    private static func validateJSONPayload(_ payload: Data) throws {
        guard String(data: payload, encoding: .utf8) != nil else { throw NetworkV1FrameError.invalidUTF8 }
        try NetworkV1JSONKeyValidator.validate(payload)
        let object: Any
        do {
            object = try JSONSerialization.jsonObject(with: payload, options: [])
        } catch {
            throw NetworkV1FrameError.invalidJSON
        }
        guard object is [String: Any] else { throw NetworkV1FrameError.nonObjectRoot }
    }
}

private struct NetworkV1JSONKeyValidator {
    private let bytes: [UInt8]
    private var index = 0

    private init(_ data: Data) {
        bytes = Array(data)
    }

    static func validate(_ data: Data) throws {
        var validator = Self(data)
        do {
            try validator.parseValue()
            validator.skipWhitespace()
            guard validator.index == validator.bytes.count else { throw SyntaxError.invalid }
        } catch let error as NetworkV1FrameError {
            throw error
        } catch {
            // JSONSerialization reports the precise syntax failure after this duplicate-key pass.
        }
    }

    private mutating func parseValue() throws {
        skipWhitespace()
        guard let byte = current else { throw SyntaxError.invalid }
        switch byte {
        case 0x7B: try parseObject()
        case 0x5B: try parseArray()
        case 0x22: _ = try parseString()
        default: try parsePrimitive()
        }
    }

    private mutating func parseObject() throws {
        index += 1
        skipWhitespace()
        if consume(0x7D) { return }
        var keys: Set<String> = []
        while true {
            skipWhitespace()
            let key = try parseString()
            guard keys.insert(key).inserted else { throw NetworkV1FrameError.duplicateJSONKey(key) }
            skipWhitespace()
            guard consume(0x3A) else { throw SyntaxError.invalid }
            try parseValue()
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { throw SyntaxError.invalid }
        }
    }

    private mutating func parseArray() throws {
        index += 1
        skipWhitespace()
        if consume(0x5D) { return }
        while true {
            try parseValue()
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { throw SyntaxError.invalid }
        }
    }

    private mutating func parseString() throws -> String {
        guard current == 0x22 else { throw SyntaxError.invalid }
        let start = index
        index += 1
        while let byte = current {
            if byte == 0x22 {
                index += 1
                let encoded = Data(bytes[start..<index])
                return try JSONDecoder().decode(String.self, from: encoded)
            }
            if byte == 0x5C {
                index += 1
                guard let escaped = current else { throw SyntaxError.invalid }
                if escaped == 0x75 {
                    index += 1
                    guard index + 4 <= bytes.count else { throw SyntaxError.invalid }
                    index += 4
                    continue
                }
            }
            index += 1
        }
        throw SyntaxError.invalid
    }

    private mutating func parsePrimitive() throws {
        let start = index
        while let byte = current, ![0x20, 0x09, 0x0A, 0x0D, 0x2C, 0x5D, 0x7D].contains(byte) {
            index += 1
        }
        guard index > start else { throw SyntaxError.invalid }
    }

    private mutating func skipWhitespace() {
        while let byte = current, [0x20, 0x09, 0x0A, 0x0D].contains(byte) { index += 1 }
    }

    private mutating func consume(_ byte: UInt8) -> Bool {
        guard current == byte else { return false }
        index += 1
        return true
    }

    private var current: UInt8? {
        index < bytes.count ? bytes[index] : nil
    }

    private enum SyntaxError: Error { case invalid }
}
