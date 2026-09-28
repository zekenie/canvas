import CanvasRPC
import Foundation
import TestKit

@MainActor let messageTests = Suite("Messages", [
    test("JSON reads and writes every kind of value, a whole number without a point, on one line") {
        let text = #"{"a":[1,2.5,true,null,"x\ny"],"b":{"c":-3}}"#
        let json = try JSON(text: text)
        expectEqual(json, ["a": [1, 2.5, true, nil, "x\ny"], "b": ["c": -3]])
        expectEqual(json.compactText, text)
        expect(!json.compactText.contains("\n"), "a message is one line")
        expectEqual(json["b"]?["c"]?.intValue, -3)
        expectEqual(try JSON(text: "\"3\"").stringValue, "3", "a string of digits stays a string")
    },
    test("printed for people and agents, a list of values takes a line, and the text reads back as the same JSON") {
        let json: JSON = ["id": "A", "bounds": [[-100, 0.5], [200, 200]], "tags": ["a", "b"], "none": [], "nested": ["x": [1, ["y": true]]], "empty": [:]]
        let text = json.prettyText
        expectEqual(text, """
            {
              "bounds": [[-100, 0.5], [200, 200]],
              "empty": {},
              "id": "A",
              "nested": {
                "x": [
                  1,
                  {
                    "y": true
                  }
                ]
              },
              "none": [],
              "tags": ["a", "b"]
            }
            """)
        expectEqual(try JSON(text: text), json)
        expectEqual(JSON.string("a \"quote\"\n").prettyText, #""a \"quote\"\n""#)
    },
    test("a request is JSON-RPC 2.0, and one that says otherwise doesn't read") {
        let request = RPCRequest(id: .number(7), method: "create", params: ["kind": "note"])
        let text = try JSON(encoding: request).compactText
        expectEqual(text, #"{"id":7,"jsonrpc":"2.0","method":"create","params":{"kind":"note"}}"#)
        expectEqual(try JSONDecoder().decode(RPCRequest.self, from: Data(text.utf8)), request)
        let notification = try JSONDecoder().decode(RPCRequest.self, from: Data(#"{"jsonrpc":"2.0","method":"ping"}"#.utf8))
        expectEqual(notification.id, nil)
        expect((try? JSONDecoder().decode(RPCRequest.self, from: Data(#"{"jsonrpc":"1.0","id":1,"method":"x"}"#.utf8))) == nil)
        expectEqual(try JSONDecoder().decode(RPCRequest.self, from: Data(#"{"jsonrpc":"2.0","id":"a","method":"x"}"#.utf8)).id, .string("a"))
    },
    test("a response carries a result or an error, with its reason and hint in data") {
        let error = RPCError(RPCError.failed, reason: "unknown_kind", "No such kind.", hint: "canvas kinds")
        let failure = RPCResponse(id: .number(1), outcome: .failure(error))
        let text = try JSON(encoding: failure).compactText
        expectEqual(text, #"{"error":{"code":-32000,"data":{"hint":"canvas kinds","reason":"unknown_kind"},"message":"No such kind."},"id":1,"jsonrpc":"2.0"}"#)
        let read = try JSONDecoder().decode(RPCResponse.self, from: Data(text.utf8))
        expectEqual(read, failure)
        guard case .failure(let decoded) = read.outcome else { return expect(false, "it's an error") }
        expectEqual(decoded.reason, "unknown_kind")
        expectEqual(decoded.hint, "canvas kinds")
        let success = RPCResponse(id: nil, outcome: .success(["id": "x"]))
        expectEqual(try JSON(encoding: success).compactText, #"{"id":null,"jsonrpc":"2.0","result":{"id":"x"}}"#)
    },
    test("a command's name is words of lowercase letters, digits and hyphens") {
        for name in ["create", "board list", "set-title", "a1"] { expect(RPC.isValidCommandName(name), name) }
        for name in ["", "Create", "board  list", " create", "create ", "1st", "cré", "a_b"] { expect(!RPC.isValidCommandName(name), name) }
    },
    test("the command named by the most words wins, and the rest are its arguments") {
        let app = AppDescription(app: AppInfo(name: "App", version: "1", pid: 1), commands: [
            CommandSpec(name: "board", summary: "", scope: .app),
            CommandSpec(name: "board list", summary: "", scope: .app),
        ])
        expectEqual(app.command(in: ["board", "list", "--all"])?.command.name, "board list")
        expectEqual(app.command(in: ["board", "list", "--all"])?.rest, ["--all"])
        expectEqual(app.command(in: ["board", "x"])?.command.name, "board")
        expect(app.command(in: ["boards"]) == nil)
        // Options, and their values, may come before the name, and go to the command.
        expectEqual(app.command(in: ["--board", "2", "board", "list", "x"])?.command.name, "board list")
        expectEqual(app.command(in: ["--board", "2", "board", "list", "x"])?.rest, ["--board", "2", "x"])
        expectEqual(app.command(in: ["--all", "board"])?.rest, ["--all"])
        expectEqual(app.command(in: ["--board=2", "x", "board"])?.command.name, nil, "x isn't an option's value")
        expect(app.command(in: ["x", "board"]) == nil, "a word that isn't an option before the name")
        let text = try JSON(encoding: app).compactText
        expect(text.contains(#""protocol":2"#), text)
        expectEqual(try JSON(text: text).decode(AppDescription.self), app)
    },
])
