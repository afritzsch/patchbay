import AppKit
import SwiftUI

/// A small syntax highlighter: keywords, strings, comments, numbers, type names and attributes, found by one pass
/// over the text. Not a parser, so it gets the odd case wrong, but it needs no grammar files.
struct Syntax {
    enum Token {
        case keyword, string, comment, number, type, attribute

        var color: NSColor {
            switch self {
            case .keyword: .systemPink
            case .string: .systemRed
            case .comment: .systemGray
            case .number: .systemPurple
            case .type: .systemTeal
            case .attribute: .systemOrange
            }
        }
    }

    var keywords: Set<String>
    var lineComment: [String] = ["//"]
    var blockComment: (open: String, close: String)? = ("/*", "*/")
    var quotes: Set<Character> = ["\"", "'"]
    /// Starts an attribute or directive like `@MainActor`, `#if` or `@decorator`.
    var attributePrefix: Set<Character> = []

    /// The syntax for a file, from its extension or name; nil for plain text.
    init?(path: String) {
        let file = (path as NSString).lastPathComponent
        let ext = (file as NSString).pathExtension.lowercased()
        guard let syntax = Self.all.first(where: { $0.extensions.contains(ext) || $0.extensions.contains(file) })?.syntax
        else { return nil }
        self = syntax
    }

    private init(_ keywords: String, configure: (inout Syntax) -> Void = { _ in }) {
        self.keywords = Set(keywords.split(separator: " ").map(String.init))
        configure(&self)
    }

    /// The tokens in `text`, as UTF-16 ranges for NSAttributedString.
    func tokens(in text: String) -> [(range: NSRange, token: Token)] {
        let chars = Array(text.utf16)
        var result: [(NSRange, Token)] = []
        var i = 0

        func at(_ s: String, _ index: Int) -> Bool {
            var j = index
            for unit in s.utf16 {
                guard j < chars.count, chars[j] == unit else { return false }
                j += 1
            }
            return true
        }
        func isWord(_ c: UInt16) -> Bool {
            c == 95 || (48...57).contains(c) || (65...90).contains(c) || (97...122).contains(c) || c > 127
        }
        func add(_ start: Int, _ token: Token) { result.append((NSRange(location: start, length: i - start), token)) }
        func skipLine() { while i < chars.count, chars[i] != 10 { i += 1 } }

        while i < chars.count {
            let start = i
            let c = chars[i]
            let previous = i > 0 ? chars[i - 1] : 10
            if let comment = lineComment.first(where: { at($0, i) }),
               comment != "#" || previous == 10 || previous == 32 || previous == 9 { // "$#" or "a#b" isn't one
                skipLine()
                add(start, .comment)
            } else if let block = blockComment, at(block.open, i) {
                i += block.open.utf16.count
                while i < chars.count, !at(block.close, i) { i += 1 }
                i = min(i + block.close.utf16.count, chars.count)
                add(start, .comment)
            } else if let quote = Character(utf16: c), quotes.contains(quote) {
                let triple = String(repeating: quote, count: 3)
                let close = at(triple, i) ? triple : String(quote)
                i += close.utf16.count
                while i < chars.count, !at(close, i), close.count == 3 || quote == "`" || chars[i] != 10 {
                    i += chars[i] == 92 ? 2 : 1 // a backslash escapes the next character
                }
                if at(close, i) { i += close.utf16.count }
                add(start, .string)
            } else if let prefix = Character(utf16: c), attributePrefix.contains(prefix),
                      i + 1 < chars.count, isWord(chars[i + 1]) {
                i += 1
                while i < chars.count, isWord(chars[i]) { i += 1 }
                add(start, .attribute)
            } else if (48...57).contains(c), !isWord(previous) {
                while i < chars.count, isWord(chars[i]) || chars[i] == 46 { i += 1 }
                add(start, .number)
            } else if isWord(c) {
                while i < chars.count, isWord(chars[i]) { i += 1 }
                let word = String(utf16CodeUnits: Array(chars[start..<i]), count: i - start)
                if keywords.contains(word) { add(start, .keyword) }
                else if (65...90).contains(c), previous != 46 { add(start, .type) }
            } else {
                i += 1
            }
        }
        return result
    }

    /// `text` coloured for a SwiftUI `Text`.
    func highlighted(_ text: String) -> AttributedString {
        var string = AttributedString(text)
        for (range, token) in tokens(in: text) {
            if let range = Range(range, in: string) { string[range].foregroundColor = Color(nsColor: token.color) }
        }
        return string
    }

    private static let cFamily = "if else for while do switch case default break continue return goto sizeof typedef struct union enum static const extern volatile inline void char short int long float double signed unsigned bool true false NULL nullptr class public private protected virtual override template typename namespace using new delete this throw try catch auto"

    private static let all: [(extensions: Set<String>, syntax: Syntax)] = [
        (["swift"], Syntax("actor any as associatedtype async await break case catch class continue default defer deinit do else enum extension fallthrough false fileprivate final for func guard if import in init inout internal is lazy let mutating nil nonisolated open operator override private protocol public repeat rethrows return self Self some static struct subscript super switch throw throws true try typealias var weak where while") {
            $0.quotes = ["\""]
            $0.attributePrefix = ["@", "#"]
        }),
        (["c", "h", "m", "mm", "cc", "cpp", "cxx", "hpp", "cs", "java", "kt", "kts", "scala", "dart"], Syntax(cFamily + " fun val var when is in object interface extends implements package import final abstract synchronized instanceof yield import from") {
            $0.attributePrefix = ["@", "#"]
        }),
        (["js", "jsx", "mjs", "cjs", "ts", "tsx"], Syntax("async await break case catch class const continue debugger default delete do else export extends false finally for from function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while yield interface type enum implements private public protected readonly as keyof") {
            $0.quotes = ["\"", "'", "`"]
            $0.attributePrefix = ["@"]
        }),
        (["go"], Syntax("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var nil true false iota") {
            $0.quotes = ["\"", "'", "`"]
        }),
        (["rs"], Syntax("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while") {
            $0.quotes = ["\""] // not ': lifetimes like 'a have no closing quote
            $0.attributePrefix = ["#"]
        }),
        (["py", "pyi"], Syntax("and as assert async await break class continue def del elif else except False finally for from global if import in is lambda None nonlocal not or pass raise return self True try while with yield match case") {
            $0.lineComment = ["#"]
            $0.blockComment = nil
            $0.attributePrefix = ["@"]
        }),
        (["rb"], Syntax("begin break case class def do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true unless until when while yield require attr_reader attr_accessor") {
            $0.lineComment = ["#"]
            $0.blockComment = nil
        }),
        (["sh", "bash", "zsh", "fish", "Makefile", "Dockerfile", "toml", "yml", "yaml", "conf", "ini", ".gitignore"], Syntax("if then else elif fi for while until do done case esac in function return local export source true false") {
            $0.lineComment = ["#"]
            $0.blockComment = nil
        }),
        (["json", "jsonc"], Syntax("true false null")),
        (["css", "scss", "less"], Syntax("important") { $0.lineComment = [] }),
        (["sql"], Syntax("select from where insert into values update set delete create table index drop alter join left right inner outer on and or not null as order by group having limit primary key references SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE INDEX DROP ALTER JOIN LEFT RIGHT INNER OUTER ON AND OR NOT NULL AS ORDER BY GROUP HAVING LIMIT PRIMARY KEY REFERENCES") {
            $0.lineComment = ["--"]
        }),
    ]
}

private extension Character {
    init?(utf16 unit: UInt16) {
        guard let scalar = Unicode.Scalar(unit) else { return nil }
        self.init(scalar)
    }
}
