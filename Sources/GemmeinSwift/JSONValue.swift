import Foundation

/// A JSON value, as your app's fields travel over the wire.
///
/// Literals do the work — `["title": "Hello", "done": false, "seats": 4]` is a
/// `[String: JSONValue]` with no ceremony. Read a field back with the typed
/// accessors: `record.data["title"]?.string`.
public enum JSONValue: Hashable, Sendable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    // ── reading ──────────────────────────────────────────────────────────
    public var string: String? { if case .string(let v) = self { return v }; return nil }
    public var int: Int? {
        switch self {
        case .int(let v): return v
        case .double(let v): return Int(exactly: v.rounded())
        default: return nil
        }
    }
    public var double: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v): return Double(v)
        default: return nil
        }
    }
    public var bool: Bool? { if case .bool(let v) = self { return v }; return nil }
    public var object: [String: JSONValue]? { if case .object(let v) = self { return v }; return nil }
    public var array: [JSONValue]? { if case .array(let v) = self { return v }; return nil }
    public var isNull: Bool { if case .null = self { return true }; return false }

    public subscript(key: String) -> JSONValue? { object?[key] }
    public subscript(index: Int) -> JSONValue? {
        guard let a = array, index >= 0, index < a.count else { return nil }
        return a[index]
    }

    // ── the bridge to Foundation, which is what JSONSerialization speaks ──
    /// The `Any` a `JSONSerialization` body is built from. `Int` stays an
    /// integer here on purpose: `{"amount":5}` must not go out as `5.0`.
    public var foundationValue: Any {
        switch self {
        case .string(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .bool(let v): return v
        case .object(let v): return v.mapValues { $0.foundationValue }
        case .array(let v): return v.map { $0.foundationValue }
        case .null: return NSNull()
        }
    }

    /// Read a `JSONSerialization` answer back. Everything the engine sends is
    /// one of these; anything unrecognised becomes `.null` rather than a
    /// throw, so one odd field never loses a whole record.
    public init(foundation value: Any) {
        switch value {
        case let v as String: self = .string(v)
        case let v as NSNumber:
            // NSNumber flattens Bool and the integer types together; the
            // objCType is the only place the difference survives.
            if CFGetTypeID(v) == CFBooleanGetTypeID() { self = .bool(v.boolValue) }
            else if let i = Int(exactly: v) { self = .int(i) }
            else { self = .double(v.doubleValue) }
        case let v as [String: Any]: self = .object(v.mapValues { JSONValue(foundation: $0) })
        case let v as [Any]: self = .array(v.map { JSONValue(foundation: $0) })
        case is NSNull: self = .null
        default: self = .null
        }
    }
}

// ── literals, so a record reads like a record ────────────────────────────
extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}
extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}
extension JSONValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) { self = .double(value) }
}
extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
extension JSONValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) { self = .null }
}
extension JSONValue: ExpressibleByArrayLiteral {
    public init(arrayLiteral elements: JSONValue...) { self = .array(elements) }
}
extension JSONValue: ExpressibleByDictionaryLiteral {
    public init(dictionaryLiteral elements: (String, JSONValue)...) {
        self = .object(Dictionary(uniqueKeysWithValues: elements))
    }
}

// ── the two directions the transport needs ───────────────────────────────
enum JSONCodec {
    /// The bytes of a JSON object body. Sorted keys: a Swift dictionary has
    /// no order of its own, and a body that reshuffles between runs cannot be
    /// asserted byte-for-byte.
    static func encode(_ fields: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: fields, options: [.sortedKeys])
    }

    static func encode(_ fields: [String: JSONValue]) throws -> Data {
        try encode(fields.mapValues { $0.foundationValue })
    }

    /// A JSON object's own text, for the places the wire carries JSON inside
    /// a query parameter (`?where={"done":false}`).
    static func string(_ fields: [String: JSONValue]) -> String {
        guard let data = try? encode(fields), let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    static func decode(_ data: Data) -> JSONValue? {
        guard let any = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { return nil }
        return JSONValue(foundation: any)
    }
}
