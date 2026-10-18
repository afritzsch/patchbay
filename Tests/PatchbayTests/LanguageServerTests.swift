import Foundation
import Testing
@testable import Patchbay

struct LanguageServerTests {
    @Test func framing() {
        let one = LSP.frame(["id": 1])
        let two = LSP.frame(["method": "x"])
        var buffer = one + two.prefix(10)
        #expect(LSP.takeMessages(from: &buffer).map { String(decoding: $0, as: UTF8.self) } == [#"{"id":1}"#])
        #expect(buffer == two.prefix(10))
        buffer += two.dropFirst(10)
        #expect(LSP.takeMessages(from: &buffer).count == 1)
        #expect(buffer.isEmpty)
        var withType = Data("Content-Type: application/json\r\nContent-Length: 2\r\n\r\n{}".utf8)
        #expect(LSP.takeMessages(from: &withType) == [Data("{}".utf8)])
    }

    @Test func positions() {
        let text = "let a = 1\n😀b\n" as NSString
        #expect(LSP.position(at: 0, in: text) == LSP.Position(line: 0, character: 0))
        #expect(LSP.position(at: 10, in: text) == LSP.Position(line: 1, character: 0))
        #expect(LSP.position(at: 12, in: text) == LSP.Position(line: 1, character: 2)) // the emoji is two UTF-16 units
        #expect(LSP.position(at: text.length, in: text) == LSP.Position(line: 2, character: 0))
        #expect(LSP.location(of: LSP.Position(line: 1, character: 3), in: text) == 13)
        // Past the line's end or the last line: kept inside, as sourcekit-lsp would crash otherwise.
        #expect(LSP.location(of: LSP.Position(line: 0, character: 99), in: text) == 9)
        #expect(LSP.location(of: LSP.Position(line: 9, character: 5), in: text) == text.length)
    }

    @Test func responses() throws {
        func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T { try JSONDecoder().decode(T.self, from: Data(json.utf8)) }
        #expect(try decode(LSP.Completions.self, #"{"isIncomplete":true,"items":[{"label":"a","textEdit":{"newText":"a()","range":{}}}]}"#)
            .items.map(\.text) == ["a()"])
        #expect(try decode(LSP.Completions.self, #"[{"label":"b","insertText":"bb"}]"#).items.map(\.text) == ["bb"])
        let markdown = try decode(LSP.Hover.self, #"{"contents":{"kind":"markdown","value":"```swift\nstruct Syntax\n```\n\nA highlighter."}}"#)
        #expect(markdown.summary == "struct Syntax")
        #expect(try decode(LSP.Hover.self, #"{"contents":["plain", {"language":"swift","value":"let x: Int"}]}"#).text == "plain\nlet x: Int")
        let range = #"{"start":{"line":7,"character":7},"end":{"line":7,"character":13}}"#
        #expect(try decode(LSP.Definition.self, #"[{"uri":"file:///a.swift","range":\#(range)}]"#).locations.first?.range.start.line == 7)
        #expect(try decode(LSP.Definition.self, #"[{"targetUri":"file:///b.swift","targetRange":\#(range),"targetSelectionRange":\#(range)}]"#)
            .locations.first?.uri == "file:///b.swift")
    }

    @Test func serverForFile() {
        #expect(LanguageServerConfig.forFile("Sources/App.swift")?.id == "swift")
        #expect(LanguageServerConfig.forFile("web/index.tsx")?.id == "typescript")
        #expect(LanguageServerConfig.forFile("notes.md") == nil)
        #expect(LanguageServerConfig.languageID(of: "a.tsx") == "typescriptreact")
    }
}
