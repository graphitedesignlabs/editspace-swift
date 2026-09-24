import Foundation

/// The language-neutral JSON value domain used by EditSpace fields and metadata.
public enum Value: Codable, Equatable, Sendable, CustomStringConvertible {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([Value])
    case object([String: Value])

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Int64.self) { self = .number(Double(value)) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([Value].self) { self = .array(value) }
        else if let value = try? container.decode([String: Value].self) { self = .object(value) }
        else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Value is not valid JSON")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }

    public var description: String {
        switch self {
        case .null: return "null"
        case .bool(let value): return String(value)
        case .number(let value): return String(value)
        case .string(let value): return value
        case .array(let values): return "[\(values.map(\.description).joined(separator: ","))]"
        case .object(let values):
            return "{" + values.keys.sorted().map { "\($0):\(values[$0]!.description)" }.joined(separator: ",") + "}"
        }
    }

    public var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    public var boolValue: Bool? { if case .bool(let value) = self { value } else { nil } }
    public var numberValue: Double? { if case .number(let value) = self { value } else { nil } }
    public var arrayValue: [Value]? { if case .array(let value) = self { value } else { nil } }
    public var objectValue: [String: Value]? { if case .object(let value) = self { value } else { nil } }

    /// Creates an array of protocol numbers without imposing a vector length.
    public static func vector(_ values: [Double]) -> Self {
        .array(values.map(Self.number))
    }

    /// Creates a numeric matrix payload. Shape validation is performed by the
    /// field-specific compatibility policy.
    public static func matrix(_ values: [Double]) -> Self {
        .array(values.map(Self.number))
    }

    /// A protocol vec2 `[x, y]`.
    public static func vector2(_ x: Double, _ y: Double) -> Self { .array([.number(x), .number(y)]) }

    /// A protocol vec3 `[x, y, z]` in the coordinate space specified by the field.
    public static func vector3(_ x: Double, _ y: Double, _ z: Double) -> Self {
        .array([.number(x), .number(y), .number(z)])
    }

    /// A protocol vec4 or quaternion `[x, y, z, w]`.
    public static func vector4(_ x: Double, _ y: Double, _ z: Double, _ w: Double) -> Self {
        .array([.number(x), .number(y), .number(z), .number(w)])
    }

    /// A column-major 4×4 matrix. Returns nil unless exactly 16 finite values are supplied.
    public static func matrix4(_ values: [Double]) -> Self? {
        guard values.count == 16, values.allSatisfy(\.isFinite) else { return nil }
        return .array(values.map(Self.number))
    }

    /// An sRGB color `[red, green, blue, alpha]`.
    public static func color(red: Double, green: Double, blue: Double, alpha: Double = 1) -> Self? {
        let components = [red, green, blue, alpha]
        guard components.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return nil }
        return .array(components.map(Self.number))
    }
}
