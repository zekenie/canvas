import LanguageModels
import TestKit

// ModelAnswer.unwrapped: SchemasTests' SyncTests hold it through SchemaPrompts' parse; these are
// the same cases, and a few of its own, read straight.

@MainActor let unwrapTests = Suite("Unwrapping an answer", [
    test("a fence line, a line of one tag alone, and the answer's own tags come off either end, trimmed") {
        let object = #"{"type": "object"}"#
        expectEqual(ModelAnswer.unwrapped("\n NO_CHANGE \n", tag: "schema"), "NO_CHANGE")
        expectEqual(ModelAnswer.unwrapped("  email required, phone \n", tag: "prompt"), "email required, phone")
        expectEqual(ModelAnswer.unwrapped(object + "\n</output>", tag: "schema"), object, "a tag's line, whatever the tag")
        expectEqual(ModelAnswer.unwrapped("<answer>\nemail required\n</answer>", tag: "prompt"), "email required")
        expectEqual(ModelAnswer.unwrapped("```json\n" + object + "\n```", tag: "schema"), object)
        expectEqual(ModelAnswer.unwrapped("```\n" + object, tag: "schema"), object)
        expectEqual(ModelAnswer.unwrapped(object + "\n```", tag: "schema"), object)
        expectEqual(ModelAnswer.unwrapped("<prompt>\nemail required, phone\n</prompt>", tag: "prompt"), "email required, phone")
        expectEqual(ModelAnswer.unwrapped("<prompt>\nNO_CHANGE\n</prompt>", tag: "prompt"), "NO_CHANGE")
    },
    test("in any nesting, until none is left; the answer's own tags on its line too, but another's stay") {
        let object = #"{"type": "object"}"#
        expectEqual(ModelAnswer.unwrapped("<schema>\n```json\n" + object + "\n```\n</schema>", tag: "schema"), object)
        expectEqual(ModelAnswer.unwrapped("```\n<schema>{}</schema>\n```", tag: "schema"), "{}")
        expectEqual(ModelAnswer.unwrapped("```\nNO_CHANGE\n```", tag: "schema"), "NO_CHANGE")
        expectEqual(ModelAnswer.unwrapped("<schema>email</schema>", tag: "prompt"), "<schema>email</schema>")
        expectEqual(ModelAnswer.unwrapped("<prompt>{}</prompt>", tag: "schema"), "<prompt>{}</prompt>")
        expectEqual(ModelAnswer.unwrapped("\n\n```json\n{}\n```\n", tag: "schema"), "{}", "trimmed first: a blank line before the fence")
    },
    test("anything else is the answer's: text around it, a tag with more than a name, a fence left with nothing inside") {
        expectEqual(ModelAnswer.unwrapped(#"Here it is: {"type": "object"}"#, tag: "schema"), #"Here it is: {"type": "object"}"#)
        expectEqual(ModelAnswer.unwrapped("<h1>\nTitle", tag: "query"), "<h1>\nTitle", "a digit: not a tag's name")
        expectEqual(ModelAnswer.unwrapped("<answer lang=\"en\">\nchore", tag: "query"), "<answer lang=\"en\">\nchore")
        expectEqual(ModelAnswer.unwrapped("```\n```", tag: "prompt"), "")
        expectEqual(ModelAnswer.unwrapped(" \n", tag: "prompt"), "")
        expectEqual(ModelAnswer.unwrapped("<query>\nchore[status=done]\n</query>", tag: "query"), "chore[status=done]")
    },
])
