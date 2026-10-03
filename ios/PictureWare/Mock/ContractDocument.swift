#if DEBUG
import Foundation

/// Read access to `api/openapi.json` (generated from `api/openapi.yaml` by
/// `ios/scripts/sync-contract.sh`): its operations, schemas and examples.
///
/// Debug only. `MockAPI` seeds itself from the examples, and the contract tests
/// decode every example with the app's models.
struct ContractDocument {
    enum Failure: LocalizedError {
        case missingResource
        case malformed(String)

        var errorDescription: String? {
            switch self {
            case .missingResource: "openapi.json is not in the bundle (run ios/scripts/sync-contract.sh and xcodegen generate)."
            case .malformed(let detail): "openapi.json: \(detail)"
            }
        }
    }

    struct Operation {
        let id: String
        let method: String
        let path: String
        let object: [String: Any]

        /// Documented ahead of the backend (`x-planned: true`): not callable yet.
        var isPlanned: Bool { object["x-planned"] as? Bool == true }
    }

    struct Example {
        let name: String
        let value: Any

        /// The example as JSON, as the server would send it.
        var json: Data {
            get throws { try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed, .sortedKeys]) }
        }
    }

    let root: [String: Any]

    init(data: Data) throws {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.malformed("not a JSON object")
        }
        self.root = root
    }

    static func bundled(in bundle: Bundle = .main) throws -> ContractDocument {
        guard let url = bundle.url(forResource: "openapi", withExtension: "json") else { throw Failure.missingResource }
        return try ContractDocument(data: Data(contentsOf: url))
    }

    // MARK: - Operations

    static let methods = ["get", "put", "post", "delete", "patch", "head", "options"]

    var operations: [Operation] {
        let paths = root["paths"] as? [String: [String: Any]] ?? [:]
        return paths.keys.sorted().flatMap { path in
            Self.methods.compactMap { method -> Operation? in
                guard let object = paths[path]?[method] as? [String: Any] else { return nil }
                return Operation(id: object["operationId"] as? String ?? "\(method) \(path)",
                                 method: method.uppercased(), path: path, object: object)
            }
        }
    }

    func operation(_ id: String) throws -> Operation {
        guard let operation = operations.first(where: { $0.id == id }) else {
            throw Failure.malformed("no operation \(id)")
        }
        return operation
    }

    /// Status code -> response object (with `$ref`s to `components/responses` followed).
    func responses(of operation: Operation) -> [String: [String: Any]] {
        let raw = operation.object["responses"] as? [String: [String: Any]] ?? [:]
        return raw.mapValues(resolve)
    }

    /// The JSON body of a response or request: `content["application/json"]`.
    func jsonContent(_ object: [String: Any]) -> [String: Any]? {
        (object["content"] as? [String: Any])?["application/json"] as? [String: Any]
    }

    func requestContent(of operation: Operation) -> [String: Any]? {
        (operation.object["requestBody"] as? [String: Any]).map(resolve).flatMap(jsonContent)
    }

    /// The `examples` map (in name order) plus a single `example`, if any.
    func examples(in content: [String: Any]) -> [Example] {
        var result: [Example] = []
        if let single = content["example"] { result.append(Example(name: "example", value: single)) }
        let named = content["examples"] as? [String: Any] ?? [:]
        for name in named.keys.sorted() {
            guard let entry = named[name] as? [String: Any] else { continue }
            let resolved = resolve(entry)
            if let value = resolved["value"] { result.append(Example(name: name, value: value)) }
        }
        return result
    }

    /// Examples of the JSON body for one operation's response status.
    func responseExamples(_ operationID: String, status: String) throws -> [Example] {
        let operation = try operation(operationID)
        guard let response = responses(of: operation)[status], let content = jsonContent(response) else { return [] }
        return examples(in: content)
    }

    // MARK: - References

    /// Follows a local `$ref` (`#/components/...`), repeatedly.
    func resolve(_ object: [String: Any]) -> [String: Any] {
        var object = object
        var hops = 0
        while let ref = object["$ref"] as? String, hops < 16, let target = lookup(ref) {
            object = target
            hops += 1
        }
        return object
    }

    func lookup(_ ref: String) -> [String: Any]? {
        guard ref.hasPrefix("#/") else { return nil }
        var node: Any = root
        for part in ref.dropFirst(2).split(separator: "/") {
            let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            guard let next = (node as? [String: Any])?[key] else { return nil }
            node = next
        }
        return node as? [String: Any]
    }
}
#endif
