import Foundation
@testable import PictureWare

/// The contract as shipped in the test bundle (`api/openapi.json`).
enum Contract {
    private final class BundleToken {}

    static func load() throws -> ContractDocument {
        try ContractDocument.bundled(in: Bundle(for: BundleToken.self))
    }
}

/// A deliberately small OpenAPI 3.0 schema checker: `$ref`, `type` (+ `nullable`),
/// `required`, `properties`, `additionalProperties`, `items`, `enum`, `minimum`/`maximum`,
/// `minLength`/`maxLength`, `oneOf`, and the `date-time`/`date`/`uri` formats. Enough to check what the app sends.
struct SchemaValidator {
    let contract: ContractDocument

    /// Problems found, as `path: message`; empty when the value matches.
    func errors(_ value: Any, against schema: [String: Any], at path: String = "$") -> [String] {
        let schema = contract.resolve(schema)

        if value is NSNull {
            return schema["nullable"] as? Bool == true ? [] : ["\(path): null is not allowed"]
        }
        if let options = schema["oneOf"] as? [[String: Any]] {
            let matching = options.filter { errors(value, against: $0, at: path).isEmpty }
            return matching.count == 1 ? [] : ["\(path): matches \(matching.count) of the oneOf schemas"]
        }
        if let allowed = schema["enum"] as? [Any],
           !allowed.contains(where: { ($0 as? NSObject)?.isEqual(value) == true }) {
            return ["\(path): \(value) is not one of \(allowed)"]
        }

        switch schema["type"] as? String {
        case "object":
            guard let object = value as? [String: Any] else { return ["\(path): expected an object"] }
            return objectErrors(object, schema: schema, path: path)
        case "array":
            guard let array = value as? [Any] else { return ["\(path): expected an array"] }
            let items = schema["items"] as? [String: Any] ?? [:]
            return array.enumerated().flatMap { errors($1, against: items, at: "\(path)[\($0)]") }
        case "string":
            guard let string = value as? String else { return ["\(path): expected a string"] }
            switch schema["format"] as? String {
            case "date-time" where APICoding.parseDate(string) == nil:
                return ["\(path): \(string) is not an RFC 3339 date-time"]
            case "uri" where URL(string: string)?.scheme == nil:
                return ["\(path): \(string) is not a URI"]
            case "date" where CalendarDate(string) == nil:
                return ["\(path): \(string) is not a YYYY-MM-DD date"]
            default:
                break
            }
            if let min = schema["minLength"] as? Int, string.count < min {
                return ["\(path): shorter than \(min)"]
            }
            if let max = schema["maxLength"] as? Int, string.count > max {
                return ["\(path): longer than \(max)"]
            }
            return []
        case "number", "integer":
            guard let number = value as? NSNumber, !Self.isBool(number) else { return ["\(path): expected a number"] }
            var problems: [String] = []
            if let minimum = schema["minimum"] as? Double, number.doubleValue < minimum {
                problems.append("\(path): \(number) < minimum \(minimum)")
            }
            if let maximum = schema["maximum"] as? Double, number.doubleValue > maximum {
                problems.append("\(path): \(number) > maximum \(maximum)")
            }
            return problems
        case "boolean":
            guard let number = value as? NSNumber, Self.isBool(number) else { return ["\(path): expected a boolean"] }
            return []
        default:
            return []
        }
    }

    private func objectErrors(_ object: [String: Any], schema: [String: Any], path: String) -> [String] {
        var problems: [String] = []
        let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
        for key in schema["required"] as? [String] ?? [] where object[key] == nil {
            problems.append("\(path): missing required \(key)")
        }
        for (key, value) in object {
            if let property = properties[key] {
                problems += errors(value, against: property, at: "\(path).\(key)")
            } else if schema["additionalProperties"] as? Bool == false {
                problems.append("\(path): unknown property \(key)")
            } else if let additional = schema["additionalProperties"] as? [String: Any] {
                problems += errors(value, against: additional, at: "\(path).\(key)")
            }
        }
        return problems
    }

    /// The smallest instance the schema allows that is still built from `value`: optional
    /// properties dropped and nullable ones set to null. Decoding it checks that the app
    /// doesn't depend on anything the contract doesn't promise.
    func minimal(_ value: Any, schema: [String: Any]) -> Any {
        let schema = contract.resolve(schema)
        if schema["nullable"] as? Bool == true { return NSNull() }
        switch schema["type"] as? String {
        case "object":
            guard var object = value as? [String: Any] else { return value }
            let required = Set(schema["required"] as? [String] ?? [])
            let properties = schema["properties"] as? [String: [String: Any]] ?? [:]
            object = object.filter { required.contains($0.key) }
            for (key, child) in object {
                if let property = properties[key] { object[key] = minimal(child, schema: property) }
            }
            return object
        case "array":
            guard let array = value as? [Any] else { return value }
            let items = schema["items"] as? [String: Any] ?? [:]
            return array.map { minimal($0, schema: items) }
        default:
            return value
        }
    }

    private static func isBool(_ number: NSNumber) -> Bool {
        CFGetTypeID(number) == CFBooleanGetTypeID()
    }
}
