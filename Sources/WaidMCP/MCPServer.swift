import Foundation

public struct ToolError: Error, CustomStringConvertible {
    public let description: String
    public init(_ description: String) { self.description = description }
}

/// Typed access to a tool call's `arguments` object.
public struct Arguments {
    public let values: [String: JSONValue]

    public init(_ values: [String: JSONValue]) { self.values = values }

    public func string(_ key: String) throws -> String? {
        switch values[key] {
        case nil, .null?: return nil
        case .string(let v)?: return v
        default: throw ToolError("argument \"\(key)\" must be a string")
        }
    }

    public func requiredString(_ key: String) throws -> String {
        guard let v = try string(key) else { throw ToolError("missing required argument \"\(key)\"") }
        return v
    }

    public func int(_ key: String) throws -> Int? {
        switch values[key] {
        case nil, .null?: return nil
        case .number(let v)? where v.rounded() == v: return Int(v)
        default: throw ToolError("argument \"\(key)\" must be an integer")
        }
    }

    public func bool(_ key: String) throws -> Bool? {
        switch values[key] {
        case nil, .null?: return nil
        case .bool(let v)?: return v
        default: throw ToolError("argument \"\(key)\" must be a boolean")
        }
    }

    public func strings(_ key: String) throws -> [String]? {
        switch values[key] {
        case nil, .null?: return nil
        case .array(let items)?:
            return try items.map {
                guard case .string(let s) = $0 else { throw ToolError("argument \"\(key)\" must be an array of strings") }
                return s
            }
        default: throw ToolError("argument \"\(key)\" must be an array of strings")
        }
    }

    public func ints(_ key: String) throws -> [Int64]? {
        switch values[key] {
        case nil, .null?: return nil
        case .array(let items)?:
            return try items.map {
                guard case .number(let n) = $0, n.rounded() == n else {
                    throw ToolError("argument \"\(key)\" must be an array of integers")
                }
                return Int64(n)
            }
        default: throw ToolError("argument \"\(key)\" must be an array of integers")
        }
    }
}

/// Who is calling, taken from the client's `initialize` request.
public struct CallContext: Sendable {
    public var clientName: String?

    /// Author label for anything this call writes: "agent:<client>", or
    /// "agent:unknown" for a client that didn't introduce itself.
    public var author: String {
        let name = (clientName ?? "unknown").lowercased()
            .replacingOccurrences(of: "[^a-z0-9._-]+", with: "-", options: .regularExpression)
        return "agent:" + name
    }

    public init(clientName: String? = nil) { self.clientName = clientName }
}

public struct Tool {
    public var name: String
    public var description: String
    public var inputSchema: JSONValue
    public var readOnly: Bool
    public var destructive: Bool
    public var handler: (Arguments, CallContext) throws -> Encodable

    public init(
        name: String, description: String, inputSchema: JSONValue, readOnly: Bool = false,
        destructive: Bool = false, handler: @escaping (Arguments, CallContext) throws -> Encodable
    ) {
        self.name = name
        self.description = description
        self.inputSchema = inputSchema
        self.readOnly = readOnly
        self.destructive = destructive
        self.handler = handler
    }
}

/// A minimal Model Context Protocol server over newline-delimited JSON-RPC
/// (the stdio transport). Implements initialize, ping, tools/list and
/// tools/call, which is all a tools-only server needs.
public final class MCPServer {
    public static let supportedProtocolVersions = ["2025-06-18", "2025-03-26", "2024-11-05"]

    public let name: String
    public let version: String
    public let instructions: String?
    private let tools: [Tool]
    private let toolsByName: [String: Tool]
    public private(set) var context = CallContext()

    public init(name: String, version: String, instructions: String? = nil, tools: [Tool]) {
        self.name = name
        self.version = version
        self.instructions = instructions
        self.tools = tools
        self.toolsByName = Dictionary(uniqueKeysWithValues: tools.map { ($0.name, $0) })
    }

    /// Reads requests from `input` until EOF, writing one response line per request.
    public func run(readLine: () -> String? = { Swift.readLine() }, write: (String) -> Void = MCPServer.writeStdout) {
        while let line = readLine() {
            if let response = handle(line: line) { write(response) }
        }
    }

    public static func writeStdout(_ line: String) {
        FileHandle.standardOutput.write(Data((line + "\n").utf8))
    }

    /// Handles one JSON-RPC message. Returns nil for notifications.
    public func handle(line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let message = try? JSONDecoder().decode(JSONValue.self, from: Data(trimmed.utf8)),
              case .object(let object) = message
        else { return encode(error: -32700, "parse error", id: .null) }

        let id = object["id"]
        guard let method = object["method"]?.stringValue else {
            // A response to a request we never sent; ignore.
            return id == nil ? nil : encode(error: -32600, "invalid request", id: id ?? .null)
        }
        let params = object["params"]?.objectValue ?? [:]

        guard let id else { return nil }  // notifications (initialized, cancelled, ...) need no reply

        switch method {
        case "initialize":
            context.clientName = params["clientInfo"]?["name"]?.stringValue
            let requested = params["protocolVersion"]?.stringValue
            let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
                ?? Self.supportedProtocolVersions[0]
            var result: [String: JSONValue] = [
                "protocolVersion": .string(version),
                "capabilities": ["tools": ["listChanged": false]],
                "serverInfo": ["name": .string(name), "version": .string(self.version)],
            ]
            if let instructions { result["instructions"] = .string(instructions) }
            return encode(result: .object(result), id: id)
        case "ping":
            return encode(result: [:], id: id)
        case "tools/list":
            return encode(result: ["tools": .array(tools.map(describe))], id: id)
        case "tools/call":
            guard let name = params["name"]?.stringValue else {
                return encode(error: -32602, "tools/call requires \"name\"", id: id)
            }
            guard let tool = toolsByName[name] else {
                return encode(error: -32602, "unknown tool \"\(name)\"", id: id)
            }
            return encode(result: call(tool, arguments: params["arguments"]?.objectValue ?? [:]), id: id)
        default:
            return encode(error: -32601, "method not found: \(method)", id: id)
        }
    }

    private func call(_ tool: Tool, arguments: [String: JSONValue]) -> JSONValue {
        do {
            let output = try tool.handler(Arguments(arguments), context)
            let text: String
            if let string = output as? String {
                text = string
            } else {
                let encoder = JSONEncoder()
                encoder.dateEncodingStrategy = .iso8601
                encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
                text = String(decoding: try encoder.encode(output), as: UTF8.self)
            }
            return ["content": [["type": "text", "text": .string(text)]], "isError": false]
        } catch {
            return ["content": [["type": "text", "text": .string("\(error)")]], "isError": true]
        }
    }

    private func describe(_ tool: Tool) -> JSONValue {
        [
            "name": .string(tool.name),
            "description": .string(tool.description),
            "inputSchema": tool.inputSchema,
            "annotations": [
                "readOnlyHint": .bool(tool.readOnly),
                "destructiveHint": .bool(tool.destructive),
                "openWorldHint": false,
            ],
        ]
    }

    private func encode(result: JSONValue, id: JSONValue) -> String {
        serialize(["jsonrpc": "2.0", "id": id, "result": result])
    }

    private func encode(error code: Int, _ message: String, id: JSONValue) -> String {
        serialize(["jsonrpc": "2.0", "id": id, "error": ["code": .number(Double(code)), "message": .string(message)]])
    }

    private func serialize(_ value: JSONValue) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self)
    }
}
