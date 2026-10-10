import Foundation

/// The two-stroke Record mark — the logo — as path data, and the small SVG path reader that turns
/// it into points.
///
/// The design draws the mark from two SVG paths (`RecordMark` in the web's `src/ui/record.jsx`),
/// filled with the logo gradient. Carried here as the same strings, read by `SVGPathReader`, so
/// the app draws the real mark at any size rather than a bitmap of it, and a test can hold the
/// reading to the path's own bounds.
enum RecordMark {
    /// The SVG `viewBox` the paths are drawn in: x, y, width, height.
    static let viewBox = (x: 49.6, y: 100.8, width: 400.1, height: 298.2)

    static let upperStroke =
        "m52.06 268.55l31.98-31.89 5.57-5.58 9.92-9.89 25.69-25.68 28.15-28.15 5.55-5.56 10.84-10.84 " +
        "8.51-8.53 9.7-9.72 4.95-4.95 6.2-6.18q1.75-1.76 3.62-3.41c1.43-1.32 3.15-2.34 4.61-3.65 2.3-" +
        "1.36 4.43-3.02 6.8-4.28 1.43-0.76 3.05-1.2 4.33-2.19 1.7-0.31 3.15-1.46 4.81-1.94 0.68-0.62 " +
        "1.7-0.78 2.61-0.93 2.34-0.38 4.57-1.27 6.81-2.05 0.79-0.27 1.78 0.03 2.47-0.43 2.57-1.29 5.7" +
        "3-0.55 8.52-1.23 2.15-0.52 4.42-0.28 6.64-0.27 4.24 0.02 8.62-0.17 12.68 1.04 2.44 0.72 4.92" +
        " 1.35 7.43 1.76 1.9 0.21 3.82 0.8 5.44 1.8 1.55 0.95 3.46 1.16 5.08 1.99 2.82 1.46 5.58 3.08" +
        " 8.35 4.65 1.85 1.06 3.3 2.81 5.26 3.69 3.27 3.24 6.84 6.2 10.11 9.46l44.8 44.86 6.34 6.34c0" +
        ".53 0.55 1.57 0.92 1.57 1.7 0 0.82-1.03 1.28-1.61 1.86l-19.94 20.1c-17.01 17.02-33.71 34.38-" +
        "51.06 51.05-3.4 3.22-6.47 6.81-9.98 9.9-3.25 3.36-6.63 6.59-9.93 9.89l-13.3 13.26-10.21 10.1" +
        "7c-0.52 0.5-0.84 1.48-1.55 1.48-1 0-1.45-1.37-2.16-2.08l-11.76-11.75c-3.38-3.35-6.06-7.44-8." +
        "2-11.69-2.23-4.46-2.5-9.9-1.91-14.85 0.56-4.73 2.57-9.37 5.26-13.3 1.84-2.69 4.4-4.79 6.71-7" +
        ".07l54.67-54.49c0.76-0.78 2.54-1.46 2.14-2.48-0.68-1.7-2.59-2.59-3.91-3.86l-5.83-5.72c-4.82-" +
        "4.55-10.81-8.81-17.37-9.61-4.89-0.59-10.01-1.23-14.77 0.02-2.56 0.67-5.45 0.85-7.54 2.48-1.3" +
        "8 1.06-2.94 1.96-4.6 2.46-0.74 0.22-1.21 0.97-1.86 1.38-2.05 1.28-3.73 3.09-5.41 4.81-3.06 3" +
        ".12-6.33 6.06-9.27 9.28l-4.37 4.34-12.2 12.2-19.96 19.96q-1.93 1.91-3.86 3.82c-1.91 1.74-3.7" +
        "1 3.59-5.49 5.46-1.81 1.92-3.81 3.63-5.56 5.57-1.66 1.65-3.46 3.17-4.98 4.96-1.05 1.01-2.11 " +
        "2.02-3.14 3.07l-10.83 10.84c-4.39 4.46-8.89 8.83-13.3 13.27l-8.06 8.08c-1.53 1.55-3.31 2.82-" +
        "4.93 4.28-2.69 1.61-5.27 3.44-8.04 4.88-1.98 1.02-4.32 1.31-6.19 2.51-4.28 0.51-8.38 2.35-12" +
        ".69 2.48-4.43 0.14-9.03 0.58-13.3-0.66-1.94-0.57-3.87-1.24-5.87-1.48-4.14-0.46-7.52-3.66-11." +
        "45-5.05-2.08-2.03-4.95-3.13-7.09-5.1-0.59-0.57-1.28-1.04-1.88-1.6-0.3-0.29-0.91-0.47-0.89-0." +
        "88 0.07-1 1.43-1.42 2.13-2.13z"

    static let lowerStroke =
        "m133.21 308.73l1.23-1.24 6.92-6.81c3.19-3.2 6.15-6.8 9.99-9.19 4.55-2.82 9.83-4.8 15.16-5.24" +
        " 6.73-0.55 13.85 1.83 19.49 5.55 2.43 1.62 4.39 3.87 6.5 5.89l9.58 9.67 17.61 17.76 6.52 6.2" +
        "9c4.97 4.96 12.12 7.67 18.98 9.18 3.99 0.87 8.19-0.12 12.27-0.56 6.81-0.48 13.06-5.13 17.94-" +
        "9.92l21.75-21.69 3.73-3.72 76.36-76.4c3.6-3.65 7.8-6.76 12.3-9.21 1.79-0.97 3.69-1.71 5.57-2" +
        ".45 0.9-0.36 2-0.3 2.78-0.87 8.83-2.14 18.5-3.15 27.22-0.67 2.61 0.74 5.29 1.32 7.74 2.47 1." +
        "67 0.77 3.16 2.01 4.95 2.47 1.16 1.08 2.65 1.72 4.02 2.51 2.05 1.2 3.75 2.92 5.56 4.45 0.65 " +
        "0.66 1.84 1.01 2.01 1.92 0.11 0.53-0.67 0.85-1.08 1.21-0.54 0.49-1.02 1.04-1.55 1.54l-4.32 4" +
        ".35-15.47 15.45-37.43 37.44c-3.44 3.55-7.11 6.9-10.45 10.53-2.7 2.89-5.47 5.71-8.4 8.36-1.37" +
        " 1.37-2.64 2.85-4.04 4.18l-14.33 14.37-44.37 44.25c-3.1 3.1-6.08 6.34-9.36 9.27-2.09 2.03-4." +
        "58 3.62-6.8 5.52-3.13 2.01-6.27 4.11-9.67 5.62-0.74 0.66-1.73 1.05-2.7 1.23-0.9 0.17-1.65 0." +
        "77-2.48 1.14-1.4 0.63-2.92 0.91-4.33 1.53-0.89 0.4-2 0.25-2.85 0.74-2.57 1.48-5.92 0.86-8.73" +
        " 1.86-1.71 0.61-3.65 0.23-5.43 0.62-6.76 1.47-13.83-0.66-20.73-1.29-1.69-0.14-3.26-1.01-4.94" +
        "-1.23-2.6-0.26-4.85-2.1-7.43-2.5-2.38-0.72-4.39-2.49-6.8-3.1-2.52-2.06-5.6-3.32-8.35-5.02-6." +
        "26-3.88-11.33-9.47-16.4-14.8l-3.93-3.93-16.17-16.22-3.1-3.07-4.21-4.22-18.68-18.77c-1.94-1.9" +
        "9-3.97-3.88-5.88-5.88q-2.75-2.53-5.25-5.29c-0.72-0.75-1.99-1.21-2.15-2.22-0.13-0.82 1.05-1.2" +
        "8 1.63-1.86z"

    static var strokes: [String] { [upperStroke, lowerStroke] }
}

/// One absolute drawing command, in the path's own coordinates.
enum PathCommand: Equatable, Sendable {
    case move(x: Double, y: Double)
    case line(x: Double, y: Double)
    case quad(x: Double, y: Double, cx: Double, cy: Double)
    case cubic(x: Double, y: Double, c1x: Double, c1y: Double, c2x: Double, c2y: Double)
    case close
}

/// Reads SVG path data — `M L H V C S Q T Z`, absolute and relative, with implicit repeats —
/// into absolute `PathCommand`s. Arcs are not read: the mark has none, and a path that uses one
/// is refused (`nil`) rather than drawn wrong.
enum SVGPathReader {

    static func read(_ data: String) -> [PathCommand]? {
        var tokens = Tokens(data)
        var commands: [PathCommand] = []
        var current = (x: 0.0, y: 0.0)
        var start = (x: 0.0, y: 0.0)
        var lastControl: (x: Double, y: Double)?
        var lastQuadControl: (x: Double, y: Double)?
        var command: Character?

        while let next = tokens.peekCommand() ?? command {
            if tokens.peekCommand() != nil { tokens.consumeCommand() }
            command = next
            let relative = next.isLowercase
            let ox = relative ? current.x : 0
            let oy = relative ? current.y : 0

            switch next.lowercased() {
            case "m":
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                current = (ox + x, oy + y)
                start = current
                commands.append(.move(x: current.x, y: current.y))
                // Pairs after a move are lines, in the move's own case.
                command = relative ? "l" : "L"
                lastControl = nil; lastQuadControl = nil
            case "l":
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                current = (ox + x, oy + y)
                commands.append(.line(x: current.x, y: current.y))
                lastControl = nil; lastQuadControl = nil
            case "h":
                guard let x = tokens.number() else { return nil }
                current = (ox + x, current.y)
                commands.append(.line(x: current.x, y: current.y))
                lastControl = nil; lastQuadControl = nil
            case "v":
                guard let y = tokens.number() else { return nil }
                current = (current.x, oy + y)
                commands.append(.line(x: current.x, y: current.y))
                lastControl = nil; lastQuadControl = nil
            case "c":
                guard let a = tokens.number(), let b = tokens.number(),
                      let c = tokens.number(), let d = tokens.number(),
                      let x = tokens.number(), let y = tokens.number() else { return nil }
                let c2 = (ox + c, oy + d)
                current = (ox + x, oy + y)
                commands.append(.cubic(
                    x: current.x, y: current.y, c1x: ox + a, c1y: oy + b, c2x: c2.0, c2y: c2.1))
                lastControl = c2; lastQuadControl = nil
            case "s":
                guard let c = tokens.number(), let d = tokens.number(),
                      let x = tokens.number(), let y = tokens.number() else { return nil }
                let c1 = lastControl.map { (2 * current.x - $0.x, 2 * current.y - $0.y) }
                    ?? (current.x, current.y)
                let c2 = (ox + c, oy + d)
                current = (ox + x, oy + y)
                commands.append(.cubic(
                    x: current.x, y: current.y, c1x: c1.0, c1y: c1.1, c2x: c2.0, c2y: c2.1))
                lastControl = c2; lastQuadControl = nil
            case "q":
                guard let a = tokens.number(), let b = tokens.number(),
                      let x = tokens.number(), let y = tokens.number() else { return nil }
                let control = (ox + a, oy + b)
                current = (ox + x, oy + y)
                commands.append(.quad(x: current.x, y: current.y, cx: control.0, cy: control.1))
                lastQuadControl = control; lastControl = nil
            case "t":
                guard let x = tokens.number(), let y = tokens.number() else { return nil }
                let control = lastQuadControl.map { (2 * current.x - $0.x, 2 * current.y - $0.y) }
                    ?? (current.x, current.y)
                current = (ox + x, oy + y)
                commands.append(.quad(x: current.x, y: current.y, cx: control.0, cy: control.1))
                lastQuadControl = control; lastControl = nil
            case "z":
                commands.append(.close)
                current = start
                command = nil
                lastControl = nil; lastQuadControl = nil
            default:
                return nil
            }
            if command == nil, tokens.isAtEnd { break }
            if tokens.isAtEnd { break }
        }
        return tokens.isAtEnd ? commands : nil
    }

    /// The smallest box holding every end point and control point.
    static func bounds(_ commands: [PathCommand]) -> (minX: Double, minY: Double, maxX: Double, maxY: Double)? {
        var xs: [Double] = []
        var ys: [Double] = []
        for command in commands {
            switch command {
            case .move(let x, let y), .line(let x, let y):
                xs.append(x); ys.append(y)
            case .quad(let x, let y, let cx, let cy):
                xs += [x, cx]; ys += [y, cy]
            case .cubic(let x, let y, let c1x, let c1y, let c2x, let c2y):
                xs += [x, c1x, c2x]; ys += [y, c1y, c2y]
            case .close:
                break
            }
        }
        guard let minX = xs.min(), let maxX = xs.max(), let minY = ys.min(), let maxY = ys.max()
        else { return nil }
        return (minX, minY, maxX, maxY)
    }

    /// The number and command scanner. SVG lets numbers run together — `1.5.5` is `1.5`, `.5`, and
    /// `2-3` is `2`, `-3` — so a number ends at a second dot or a sign that is not an exponent's.
    private struct Tokens {
        private let scalars: [Unicode.Scalar]
        private var index = 0

        init(_ text: String) { scalars = Array(text.unicodeScalars) }

        var isAtEnd: Bool {
            var probe = index
            while probe < scalars.count, Tokens.isSeparator(scalars[probe]) { probe += 1 }
            return probe >= scalars.count
        }

        private static func isSeparator(_ s: Unicode.Scalar) -> Bool {
            s == " " || s == "," || s == "\n" || s == "\t" || s == "\r"
        }

        private mutating func skipSeparators() {
            while index < scalars.count, Tokens.isSeparator(scalars[index]) { index += 1 }
        }

        mutating func peekCommand() -> Character? {
            skipSeparators()
            guard index < scalars.count else { return nil }
            let s = scalars[index]
            guard s.properties.isAlphabetic, s != "e", s != "E" else { return nil }
            return Character(s)
        }

        mutating func consumeCommand() { index += 1 }

        mutating func number() -> Double? {
            skipSeparators()
            var text = ""
            var seenDot = false
            var seenExponent = false
            while index < scalars.count {
                let s = scalars[index]
                if s == "-" || s == "+" {
                    let previous = text.last
                    guard text.isEmpty || previous == "e" || previous == "E" else { break }
                } else if s == "." {
                    guard !seenDot, !seenExponent else { break }
                    seenDot = true
                } else if s == "e" || s == "E" {
                    guard !seenExponent, !text.isEmpty else { break }
                    seenExponent = true
                } else if !(s.properties.numericType != nil && s.isASCII) {
                    break
                }
                text.unicodeScalars.append(s)
                index += 1
            }
            return Double(text)
        }
    }
}
