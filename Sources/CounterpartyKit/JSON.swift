import Foundation

// exchanges send numbers both as json numbers and as strings, this reads either
struct Num: Decodable, Sendable {
    let value: Double

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
            return
        }
        let text = try container.decode(String.self)
        guard let number = Double(text) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "not a number: \(text)")
        }
        value = number
    }
}

// untyped json, for messages that are positional arrays (bitfinex) or mixed rows (aggr history)
enum JSON: Decodable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSON])
    case object([String: JSON])

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([JSON].self) {
            self = .array(value)
        } else {
            self = .object(try container.decode([String: JSON].self))
        }
    }

    subscript(index: Int) -> JSON? {
        guard case .array(let items) = self, items.indices.contains(index) else { return nil }
        return items[index]
    }

    subscript(key: String) -> JSON? {
        guard case .object(let fields) = self else { return nil }
        return fields[key]
    }

    var number: Double? {
        if case .number(let value) = self { return value }
        return nil
    }

    var string: String? {
        if case .string(let value) = self { return value }
        return nil
    }

    var array: [JSON]? {
        if case .array(let items) = self { return items }
        return nil
    }

    // javascript truthiness, aggr's bitfinex filter relies on it
    var truthy: Bool {
        switch self {
        case .null: false
        case .bool(let value): value
        case .number(let value): value != 0
        case .string(let value): !value.isEmpty
        case .array, .object: true
        }
    }
}

func decode<T: Decodable>(_ type: T.Type, _ data: Data) -> T? {
    try? JSONDecoder().decode(type, from: data)
}
