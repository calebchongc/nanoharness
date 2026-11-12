// Core-format compatibility with the exact Loro package retained by iOS.
// This is not an iOS UI or network transport test.
import Foundation
import Loro

func object(_ value: LoroValue) -> Any {
    switch value {
    case .null: return NSNull()
    case .bool(let v): return v
    case .double(let v): return v
    case .i64(let v): return v
    case .binary(let v): return Array(v)
    case .string(let v): return v
    case .list(let v): return v.map(object)
    case .map(let v): return v.mapValues(object)
    case .container: fatalError("deep value unexpectedly holds a container")
    }
}
let args = CommandLine.arguments
precondition(args.count == 4, "snapshot, binary VV, output directory required")
let doc = LoroDoc()
_ = try doc.importWith(bytes: Data(contentsOf: URL(fileURLWithPath: args[1])), origin: "synthetic-compatibility")
let vv = try VersionVector.decode(bytes: Data(contentsOf: URL(fileURLWithPath: args[2])))
precondition(doc.oplogVv().includesVv(other: vv), "retained Swift core must include the Rust/Zig VV")
let root = object(doc.getDeepValue()) as! [String: Any]
let messages = root["messages"] as! [[String: Any]]
precondition(messages.count >= 130)
precondition(messages[0]["id"] as? String == "rust-0")
precondition(messages[65]["id"] as? String == "rust-65")
let assistant = messages.first { $0["id"] as? String == "rust-assistant" }!
let parts = assistant["parts"] as! [[String: Any]]
precondition(parts.contains { $0["kind"] as? String == "reasoning" && $0["reasoning"] as? String == "thought 🦀" })
precondition(parts.contains { $0["kind"] as? String == "tool" && ($0["call"] as? [String: Any])?["kind"] as? String == "exec" })
let commands = root["commands"] as! [[String: Any]]
let command = commands.first { $0["id"] as? String == "command-rust" }!
precondition(command["status"] as? String == "applied")
precondition((command["basedOn"] as? [String: Any])?["turnId"] as? String == "turn-synthetic")
precondition((root["queue"] as? [[String: Any]]) != nil)
let out = URL(fileURLWithPath: args[3])
try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
// Native Swift emits a genuine Loro change, not a JSON-shaped surrogate.
let before = doc.oplogVv()
try doc.getMap(id: "meta").insert(key: "swiftCompatibility", v: "Swift 1.13.3 🦀")
doc.commit()
try doc.export(mode: .updates(from: before)).write(to: out.appendingPathComponent("swift.update"))
try doc.export(mode: .snapshot).write(to: out.appendingPathComponent("swift.snapshot"))
try doc.oplogVv().encode().write(to: out.appendingPathComponent("swift.vv"))
print("RESULT:{\"swiftPackage\":\"1.13.3\",\"typedFields\":true,\"binaryVV\":true,\"messages\":\(messages.count),\"emittedRealUpdate\":true}")
