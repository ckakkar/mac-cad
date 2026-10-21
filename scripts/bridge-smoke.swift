import Foundation
let engine = cad_create()!
defer { cad_destroy(engine) }
func request(_ value: [String:Any]) throws -> [String:Any] {
    let data = try JSONSerialization.data(withJSONObject:value)
    let result = String(decoding:data,as:UTF8.self).withCString { cad_request(engine,$0)! }
    defer {cad_string_free(result)}
    let response = try JSONSerialization.jsonObject(with:Data(String(cString:result).utf8)) as! [String:Any]
    precondition(response["ok"] as? Bool == true,"\(response)")
    return response["value"] as! [String:Any]
}
_ = try request(["op":"command","text":"LINE 1000000000,1000000000 1000000010,1000000000"])
_ = try request(["op":"select_all"])
_ = try request(["op":"command","text":"MOVE 5,2"])
let moved = try request(["op":"serialize"])
_ = try request(["op":"command","text":"UNDO"])
_ = try request(["op":"command","text":"REDO"])
let afterRedo = try request(["op":"serialize"])
precondition(NSDictionary(dictionary:moved).isEqual(to:afterRedo))
let saved = try JSONSerialization.data(withJSONObject:afterRedo)
let destination = FileManager.default.temporaryDirectory.appendingPathComponent("maccad-bridge-\(UUID().uuidString).maccad")
defer { try? FileManager.default.removeItem(at:destination) }
try saved.write(to:destination,options:.atomic)
_ = try request(["op":"load","document":try JSONSerialization.jsonObject(with:Data(contentsOf:destination))])
let batch = cad_render(engine,1e9,1e9,1e9+100,1e9+100,0.1)!
defer { cad_batch_free(batch) }
var count = 0
let segments = cad_batch_segments(batch,&count)!
precondition(count == 1 && segments[0].ax == 1e9+5 && segments[0].by == 1e9+2)
print("Swift → C → Rust: draw/select/move/undo/redo/atomic save/reopen/binary scene passed.")
