//
//  Consumer.swift
//  Consumer
//
//  Version 0.3.0
//
//  Created by Nick Lockwood on 01/03/2018.
//  Copyright © 2018 Nick Lockwood. All rights reserved.
//
//  Distributed under the permissive MIT license
//  Get the latest version from here:
//
//  https://github.com/nicklockwood/Consumer
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.
//

import Foundation

// MARK: Consumer

public indirect enum Consumer<Label: Hashable>: Equatable {
    /// Primitives
    case string(String)
    case charset(Charset)

    /// Combinators
    case any([Consumer])
    case sequence([Consumer])
    case optional(Consumer)
    case oneOrMore(Consumer)

    /// Transforms
    case flatten(Consumer)
    case discard(Consumer)
    case replace(Consumer, String)

    /// References
    case label(Label, Consumer)
    case reference(Label)
}

// MARK: Matching

public extension Consumer {
    /// Parse input and return matched result
    func match(_ input: String) throws -> Match {
        return try _match(input)
    }

    /// Source location
    struct Location: Equatable {
        fileprivate var source: String.UnicodeScalarView
        public let range: Range<String.Index>
        public var offset: (line: Int, column: Int) { return _offset }
    }

    /// Abstract syntax tree returned by consumer
    indirect enum Match: Equatable {
        case token(String, Location)
        case node(Label?, [Match])

        /// The location of the match in the original source (if known)
        public var location: Location? { return _location }

        /// Transform generic AST to application-specific form
        func transform(_ fn: Transform) rethrows -> Any? {
            return try _transform(fn)
        }
    }

    /// Opaque type used for efficient character matching
    public struct Charset: Hashable {
        fileprivate let characterSet: CharacterSet
        let inverted: Bool
    }

    /// Closure for transforming a Match to an application-specific data type
    typealias Transform = (_ name: Label, _ values: [Any]) throws -> Any?

    /// A Parsing error
    struct Error: Swift.Error {
        public indirect enum Kind {
            case expected(Consumer)
            case unexpectedToken
            case custom(Swift.Error)
        }

        public var kind: Kind
        public var location: Location?
        public var remaining: Substring.UnicodeScalarView? {
            return _remaining
        }
    }
}

// MARK: Syntax sugar

extension Consumer: ExpressibleByStringLiteral, ExpressibleByArrayLiteral {
    /// Create .string() consumer from a string literal
    public init(stringLiteral: String) {
        let scalars = stringLiteral.unicodeScalars
        if scalars.count == 1, let char = scalars.first {
            self = .character(char)
        } else {
            self = .string(stringLiteral)
        }
    }

    /// Create .sequence() consumer from an array literal
    public init(arrayLiteral: Consumer...) {
        self = .sequence(arrayLiteral)
    }

    /// Converts two consumers into an .any() consumer
    public static func | (lhs: Consumer, rhs: Consumer) -> Consumer {
        switch (lhs, rhs) {
        case let (.any(lhs), .any(rhs)):
            return .any(lhs + rhs)
        case let (.any(lhs), rhs):
            return .any(lhs + [rhs])
        case let (lhs, .any(rhs)):
            return .any([lhs] + rhs)
        case let (.charset(lhs), .charset(rhs)):
            return .charset(lhs._union(rhs))
        case let (lhs, rhs):
            return .any([lhs, rhs])
        }
    }
}

/// MARK: Character sets

public extension Consumer {
    /// Match a character
    static func character(_ c: UnicodeScalar) -> Consumer {
        return .character(in: c ... c)
    }

    /// Match character in range
    static func character(in range: ClosedRange<UnicodeScalar>) -> Consumer {
        return .character(in: CharacterSet(charactersIn: range))
    }

    /// Match character in string
    static func character(in string: String) -> Consumer {
        return .character(in: CharacterSet(charactersIn: string))
    }

    /// Match character in set
    static func character(in set: CharacterSet) -> Consumer {
        return .charset(Charset(characterSet: set, inverted: false))
    }

    /// Match any character except the one(s) specified
    static func anyCharacter(except characters: UnicodeScalar...) -> Consumer {
        let set = CharacterSet(charactersIn: characters.map(String.init).joined())
        return .anyCharacter(except: set)
    }

    /// Match any character except the specified set
    static func anyCharacter(except set: CharacterSet) -> Consumer {
        return .charset(Charset(characterSet: set, inverted: true))
    }
}

/// MARK: Composite rules

public extension Consumer {
    /// Matches a list of one or more of the specified consumer
    static func zeroOrMore(_ consumer: Consumer) -> Consumer {
        return .optional(.oneOrMore(consumer))
    }

    /// Matches one or more of the specified consumer, interleaved with a separator
    static func interleaved(_ consumer: Consumer, _ separator: Consumer) -> Consumer {
        return .sequence([.zeroOrMore(.sequence([consumer, separator])), consumer])
    }
}

// MARK: Consumer implementation

extension Consumer: CustomStringConvertible {
    /// Human-readable description of what consumer matches
    public var description: String {
        switch self {
        case let .label(name, _):
            return "\(name)"
        case let .reference(name):
            return "\(name)"
        case let .string(string):
            return escapeString(string)
        case let .charset(charset):
            var results = [String]()
            for range in charset.ranges {
                let first = range.lowerBound, last = range.upperBound
                if first == last {
                    results.append(escapeCodePoint(first))
                } else if first == last - 1 {
                    results.append(escapeCodePoint(first))
                    results.append(escapeCodePoint(last))
                } else {
                    results.append("\(escapeCodePoint(first)) – \(escapeCodePoint(last))")
                }
            }
            if results.isEmpty {
                return charset.inverted ? "any character" : "nothing"
            }
            let prefix = charset.inverted ? "any character except " : ""
            switch results.count {
            case 1:
                return prefix + results[0]
            default:
                return "\(results.dropLast().map { $0 }.joined(separator: ", ")) or \(results.last!)"
            }
        case let .any(consumers):
            var descriptions = [String]()
            for consumer in consumers {
                let description = consumer.description
                if !descriptions.contains(description) {
                    descriptions.append(description)
                }
            }
            switch descriptions.count {
            case 1:
                return descriptions[0]
            case 2...:
                return "\(descriptions.dropLast().joined(separator: ", ")) or \(descriptions.last!)"
            default:
                return "nothing"
            }
        case let .sequence(consumers):
            var options = [Consumer]()
            for consumer in consumers {
                options.append(consumer)
                if !consumer._isOptional {
                    break
                }
            }
            return Consumer.any(options).description
        case let .optional(consumer),
             let .oneOrMore(consumer):
            return consumer.description
        case let .flatten(consumer),
             let .discard(consumer),
             let .replace(consumer, _):
            return consumer.description
        }
    }

    /// Equatable implementation
    public static func == (lhs: Consumer, rhs: Consumer) -> Bool {
        switch (lhs, rhs) {
        case let (.string(lhs), .string(rhs)):
            return lhs == rhs
        case let (.charset(lhs), .charset(rhs)):
            return lhs == rhs
        case let (.any(lhs), .any(rhs)),
             let (.sequence(lhs), .sequence(rhs)):
            return lhs == rhs
        case let (.optional(lhs), .optional(rhs)),
             let (.oneOrMore(lhs), .oneOrMore(rhs)),
             let (.flatten(lhs), .flatten(rhs)),
             let (.discard(lhs), .discard(rhs)):
            return lhs == rhs
        case let (.replace(lhs), .replace(rhs)):
            return lhs.0 == rhs.0 && lhs.1 == rhs.1
        case let (.label(lhs), .label(rhs)):
            return lhs.0 == rhs.0 && lhs.1 == rhs.1
        case let (.reference(lhs), .reference(rhs)):
            return lhs == rhs
        default:
            return false
        }
    }
}

private extension Consumer {
    var _isOptional: Bool {
        switch self {
        case .reference:
            // TODO: not sure if this is right, but we
            // need to avoid infinite recursion
            return false
        case let .label(_, consumer):
            return consumer._isOptional
        case .string, .charset:
            return false
        case let .any(consumers):
            return consumers.contains { $0._isOptional }
        case let .sequence(consumers):
            return !consumers.contains { !$0._isOptional }
        case .optional:
            return true
        case let .oneOrMore(consumer),
             let .flatten(consumer),
             let .discard(consumer),
             let .replace(consumer, _):
            return consumer._isOptional
        }
    }

    func _match(_ input: String) throws -> Match {
        var consumersByName = [Label: Consumer]()
        let input = input.unicodeScalars
        var index = input.startIndex
        var offset = 0

        var bestIndex = input.startIndex
        var expected: Consumer?

        func _skipString(_ string: String) -> Bool {
            let scalars = string.unicodeScalars
            var newOffset = offset
            var newIndex = index
            for c in scalars {
                guard newIndex < input.endIndex, input[newIndex] == c else {
                    return false
                }
                newOffset += 1
                newIndex = input.index(after: newIndex)
            }
            index = newIndex
            offset = newOffset
            return true
        }

        func _skipCharacter(_ charset: Charset) -> Bool {
            if index < input.endIndex, charset._contains(input[index]) {
                offset += 1
                index = input.index(after: index)
                return true
            }
            return false
        }

        func _skip(_ consumer: Consumer) -> Bool {
            switch consumer {
            case let .label(name, _consumer):
                consumersByName[name] = consumer
                return _skip(_consumer)
            case let .reference(name):
                guard let consumer = consumersByName[name] else {
                    preconditionFailure("Undefined reference for consumer '\(name)'")
                }
                return _skip(consumer)
            case let .string(string):
                return _skipString(string)
            case let .charset(charset):
                return _skipCharacter(charset)
            case let .any(consumers):
                return consumers.contains(where: _skip)
            case let .sequence(consumers):
                let startIndex = index
                let startOffset = offset
                for consumer in consumers where !_skip(consumer) {
                    if index >= bestIndex {
                        bestIndex = index
                        expected = consumer
                    }
                    index = startIndex
                    offset = startOffset
                    return false
                }
                return true
            case let .optional(consumer):
                return _skip(consumer) || true
            case let .oneOrMore(consumer):
                let startIndex = index
                switch consumer {
                case let .charset(charset):
                    while _skipCharacter(charset) {}
                case let .string(string) where !string.isEmpty:
                    while _skipString(string) {}
                default:
                    var lastIndex = index
                    while _skip(consumer), index > lastIndex {
                        lastIndex = index
                    }
                }
                return index > startIndex
            case let .flatten(consumer),
                 let .discard(consumer),
                 let .replace(consumer, _):
                return _skip(consumer)
            }
        }

        func _flatten(_ consumer: Consumer) -> String? {
            switch consumer {
            case let .label(name, _consumer):
                consumersByName[name] = consumer
                return _flatten(_consumer)
            case let .reference(name):
                guard let consumer = consumersByName[name] else {
                    preconditionFailure("Undefined reference for consumer '\(name)'")
                }
                return _flatten(consumer)
            case let .string(string):
                return _skipString(string) ? string : nil
            case let .charset(charset):
                let startIndex = index
                return _skipCharacter(charset) ? String(input[startIndex]) : nil
            case let .any(consumers):
                let startIndex = index
                for consumer in consumers {
                    if let match = _flatten(consumer), index > startIndex {
                        return match
                    }
                }
                return nil
            case let .sequence(consumers):
                let startIndex = index
                let startOffset = offset
                var result = ""
                for consumer in consumers {
                    if let match = _flatten(consumer) {
                        result += match
                    } else {
                        if index >= bestIndex {
                            bestIndex = index
                            expected = consumer
                        }
                        index = startIndex
                        offset = startOffset
                        return nil
                    }
                }
                return result
            case let .optional(consumer):
                return _flatten(consumer) ?? ""
            case let .oneOrMore(consumer):
                let startIndex = index
                if case let .charset(charset) = consumer {
                    while _skipCharacter(charset) {}
                    if index > startIndex {
                        return String(input[startIndex ..< index])
                    }
                    return index > startIndex ? "" : nil
                }
                var result = ""
                var lastIndex = index
                while let match = _flatten(consumer), index > lastIndex {
                    lastIndex = index
                    result.append(match)
                }
                return index > startIndex ? result : nil
            case let .flatten(consumer):
                return _flatten(consumer)
            case let .discard(consumer):
                return _skip(consumer) ? "" : nil
            case let .replace(consumer, replacement):
                return _skip(consumer) ? replacement : nil
            }
        }

        func _match(_ consumer: Consumer) -> Match? {
            switch consumer {
            case let .label(name, _consumer):
                consumersByName[name] = consumer
                return _match(_consumer).map { match in
                    switch match {
                    case let .node(_name, matches):
                        return .node(name, _name == nil ? matches : [match])
                    default:
                        return .node(name, [match])
                    }
                }
            case let .reference(name):
                guard let consumer = consumersByName[name] else {
                    preconditionFailure("Undefined reference for consumer '\(name)'")
                }
                return _match(consumer)
            case let .string(string):
                let startIndex = index
                return _skipString(string) ? .token(
                    string, Location(source: input, range: startIndex ..< index)) : nil
            case let .charset(charset):
                let startIndex = index
                let string = String(input[startIndex])
                return _skipCharacter(charset) ? .token(
                    string, Location(source: input, range: startIndex ..< index)) : nil
            case let .any(consumers):
                let startIndex = index
                for consumer in consumers {
                    if let match = _match(consumer), index > startIndex {
                        return match
                    }
                }
                return nil
            case let .sequence(consumers):
                let startIndex = index
                let startOffset = offset
                var matches = [Match]()
                for consumer in consumers {
                    if let match = _match(consumer) {
                        switch match {
                        case let .node(name, _matches):
                            if name != nil {
                                fallthrough
                            }
                            matches += _matches
                        case .token:
                            matches.append(match)
                        }
                    } else {
                        if index >= bestIndex {
                            bestIndex = index
                            expected = consumer
                        }
                        index = startIndex
                        offset = startOffset
                        return nil
                    }
                }
                return .node(nil, matches)
            case let .optional(consumer):
                return _match(consumer) ?? .node(nil, [])
            case let .oneOrMore(consumer):
                if case let .charset(charset) = consumer {
                    let startIndex = index
                    var matches = [Match]()
                    while _skipCharacter(charset) {
                        let lastIndex = input.index(before: index)
                        matches.append(.token(
                            String(input[lastIndex]),
                            Location(source: input, range: lastIndex ..< index)))
                    }
                    return index > startIndex ? .node(nil, matches) : nil
                }
                var matches = [Match]()
                var lastIndex = index
                while let match = _match(consumer), index > lastIndex {
                    lastIndex = index
                    switch match {
                    case let .node(name, _matches):
                        if name != nil {
                            fallthrough
                        }
                        matches += _matches
                    case .token:
                        matches.append(match)
                    }
                }
                return matches.isEmpty ? nil : .node(nil, matches)
            case let .flatten(consumer):
                let startIndex = index
                return _flatten(consumer).map {
                    .token($0, Location(source: input, range: startIndex ..< index))
                }
            case let .discard(consumer):
                return _skip(consumer) ? .node(nil, []) : nil
            case let .replace(consumer, replacement):
                let startIndex = index
                return _skip(consumer) ? .token(
                    replacement, Location(source: input, range: startIndex ..< index)) : nil
            }
        }
        if let match = _match(self) {
            if index < input.endIndex {
                if bestIndex > index, let expected = expected {
                    throw Error(.expected(expected), at: bestIndex, in: input)
                }
                throw Error(.unexpectedToken, at: index, in: input)
            }
            return match
        } else {
            throw Error(.expected(expected ?? self), at: bestIndex, in: input)
        }
    }
}

// MARK: Location implementation

extension Consumer.Location: CustomStringConvertible {
    /// Human-readable description of the location
    public var description: String {
        return "\(offset.line):\(offset.column)"
    }

    /// Equatable implementation
    public static func == (lhs: Consumer.Location, rhs: Consumer.Location) -> Bool {
        return lhs.range == rhs.range
    }

    // Convenience constructor, used for testing
    static func at(_ range: CountableRange<Int>) -> Consumer.Location {
        let source = String(repeating: " ", count: range.upperBound).unicodeScalars
        let range = source.index(
            source.startIndex,
            offsetBy: range.lowerBound
        ) ..< source.endIndex
        return Consumer.Location(source: source, range: range)
    }
}

private extension Consumer.Location {
    var _offset: (line: Int, column: Int) {
        var line = 1
        var column = 1
        var wasReturn = false
        for c in source[..<range.lowerBound] {
            switch c {
            case "\n" where wasReturn:
                continue
            case "\r", "\n":
                line += 1
                column = 1
            default:
                column += 1
            }
            wasReturn = (c == "\r")
        }
        return (line: line, column: column)
    }
}

// MARK: Charset implementation

public extension Consumer.Charset {
    var hashValue: Int { return characterSet.hashValue }

    // Equatable implementation
    static func == (lhs: Consumer.Charset, rhs: Consumer.Charset) -> Bool {
        return lhs.inverted == rhs.inverted && lhs.characterSet == rhs.characterSet
    }

    // Note: this calculation is really expensive
    var ranges: [CountableClosedRange<UInt32>] {
        var ranges = [CountableClosedRange<UInt32>]()
        let bitmap: Data = characterSet.bitmapRepresentation
        var first: UInt32?, last: UInt32?
        var plane = 0, nextPlane = 8192
        for (j, byte) in bitmap.enumerated() where byte != 0 {
            if j == nextPlane {
                plane += 1
                nextPlane += 8193
                continue
            }
            for i in 0 ..< 8 where byte & 1 << i != 0 {
                let codePoint = UInt32(j - plane) * 8 + UInt32(i)
                if let _last = last, codePoint == _last + 1 {
                    last = codePoint
                } else {
                    if let first = first, let last = last {
                        ranges.append(first ... last)
                    }
                    first = codePoint
                    last = codePoint
                }
            }
        }
        if let first = first, let last = last {
            ranges.append(first ... last)
        }
        return ranges
    }
}

private extension Consumer.Charset {
    func _contains(_ char: UnicodeScalar) -> Bool {
        return characterSet.contains(char) != inverted
    }

    func _union(_ other: Consumer.Charset) -> Consumer.Charset {
        let inverted: Bool
        let set: CharacterSet
        switch (self.inverted, other.inverted) {
        case (true, true), (false, false):
            inverted = self.inverted
            set = characterSet.union(other.characterSet)
        case (true, false):
            inverted = true
            set = characterSet.subtracting(other.characterSet)
        case (false, true):
            inverted = true
            set = other.characterSet.subtracting(characterSet)
        }
        return Consumer.Charset(characterSet: set, inverted: inverted)
    }
}

// MARK: Match implementation

extension Consumer.Match: CustomStringConvertible {
    /// Lisp-like description of the AST
    public var description: String {
        func _description(_ match: Consumer.Match, _ indent: String) -> String {
            switch match {
            case let .token(string, _):
                return escapeString(string)
            case let .node(name, matches):
                switch matches.count {
                case 0:
                    return name.map { "(\($0))" } ?? "()"
                case 1:
                    let description = _description(matches[0], indent)
                    return name.map { "(\($0) \(description))" } ?? "(\(description))"
                default:
                    return """
                    (\(name.map { "\($0)" } ?? "")
                    \(indent)    \(matches.map { _description($0, indent + "    ") }.joined(separator: "\n\(indent)    "))
                    \(indent))
                    """
                }
            }
        }
        return _description(self, "")
    }

    /// Equatable implementation
    public static func == (lhs: Consumer.Match, rhs: Consumer.Match) -> Bool {
        switch (lhs, rhs) {
        case let (.token(lhs), .token(rhs)):
            return lhs.0 == rhs.0 && lhs.1 == rhs.1
        case let (.node(lhs), .node(rhs)):
            return lhs.0 == rhs.0 && lhs.1 == rhs.1
        case (.token, _), (.node, _):
            return false
        }
    }
}

private extension Consumer.Match {
    var _location: Consumer.Location? {
        switch self {
        case let .token(_, location):
            return location
        case let .node(_, matches):
            guard let source = matches.first?.location?.source,
                let startIndex = matches.first?.location?.range.lowerBound,
                let endIndex = matches.last?.location?.range.upperBound else {
                return nil
            }
            return Consumer.Location(source: source, range: startIndex ..< endIndex)
        }
    }

    func _transform(_ fn: Consumer.Transform) rethrows -> Any? {
        // TODO: warn if no matches are labelled, as transform won't work
        do {
            switch self {
            case let .token(string, _):
                return String(string)
            case let .node(name, matches):
                let values = try Array(matches.flatMap { try $0.transform(fn) })
                return try name.map { try fn($0, values) } ?? values
            }
        } catch let error as Consumer.Error {
            throw error
        } catch {
            throw Consumer.Error(error, at: location)
        }
    }
}

// MARK: Error implementation

extension Consumer.Error: CustomStringConvertible {
    /// Human-readable error description
    public var description: String {
        var token = ""
        if var remaining = self.remaining, let first = remaining.first {
            let whitespace = " \t\n\r".unicodeScalars
            if whitespace.contains(first) {
                token = String(first)
            } else {
                while let char = remaining.popFirst(),
                    !whitespace.contains(char) {
                    token.append(Character(char))
                }
            }
        }
        let offset = location.map { " at \($0)" } ?? ""
        switch kind {
        case let .expected(consumer):
            if !token.isEmpty {
                return "Unexpected token \(escapeString(token))\(offset) (expected \(consumer))"
            }
            return "Expected \(consumer)\(offset)"
        case .unexpectedToken:
            return "Unexpected token \(escapeString(token))\(offset)"
        case let .custom(error):
            return "\(error)\(offset)"
        }
    }
}

private extension Consumer.Error {
    var _remaining: Substring.UnicodeScalarView? {
        return location.map { $0.source[$0.range.lowerBound...] }
    }

    init(_ kind: Consumer.Error.Kind, at: String.Index, in source: String.UnicodeScalarView) {
        self.kind = kind
        location = Consumer.Location(source: source, range: at ..< source.endIndex)
    }

    init(_ error: Swift.Error, at: Consumer.Location?) {
        if let error = error as? Consumer.Error {
            self = error
        } else {
            kind = .custom(error)
        }
        location = at ?? location
    }
}

// Human-readable character
private func escapeCodePoint(_ codePoint: UInt32, inString _: Bool = false) -> String {
    guard let char = UnicodeScalar(codePoint),
        !CharacterSet.controlCharacters.contains(char) else {
        let hex = String(codePoint, radix: 16, uppercase: true)
        return "U+\(String(repeating: "0", count: 4 - hex.count))\(hex)"
    }
    return escapeString(String(char))
}

// Human-readable string
private func escapeString<T: StringProtocol>(_ string: T) -> String {
    var result = "'"
    for char in string.unicodeScalars {
        switch char.value {
        case 0:
            result.append("\\0")
        case 9:
            result.append("\\t")
        case 10:
            result.append("\\n")
        case 13:
            result.append("\\r")
        case let codePoint where CharacterSet.controlCharacters.contains(char):
            result.append("\\u{\(String(codePoint, radix: 16, uppercase: true))}")
        default:
            result.append(Character(char))
        }
    }
    return result + "'"
}
