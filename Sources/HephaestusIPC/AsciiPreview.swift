import Foundation

/// Renders layout zones as an ASCII box drawing. Pure.
public enum AsciiPreview {
    /// `zones` are relative (0...1, origin top-left). Each zone is numbered (1-based, matching "Zone N").
    public static func render(_ zones: [ZoneRect], width: Int = 36, height: Int = 8) -> String {
        guard !zones.isEmpty, width >= 4, height >= 3 else { return "" }
        var grid = Array(repeating: Array(repeating: Character(" "), count: width + 1), count: height + 1)

        func put(_ c: Character, _ x: Int, _ y: Int) {
            let old = grid[y][x]
            if old == " " { grid[y][x] = c }
            else if old == "+" { return }
            else if c == "+" || (old == "-" && c == "|") || (old == "|" && c == "-") { grid[y][x] = "+" }
        }
        func clamp(_ v: Int, _ hi: Int) -> Int { min(max(v, 0), hi) }

        for z in zones {
            var x0 = clamp(Int((z.x * Double(width)).rounded()), width)
            var x1 = clamp(Int(((z.x + z.w) * Double(width)).rounded()), width)
            var y0 = clamp(Int((z.y * Double(height)).rounded()), height)
            var y1 = clamp(Int(((z.y + z.h) * Double(height)).rounded()), height)
            if x1 - x0 < 2 { x1 = min(width, x0 + 2); x0 = x1 - 2 }
            if y1 - y0 < 2 { y1 = min(height, y0 + 2); y0 = y1 - 2 }
            for x in x0...x1 { put("-", x, y0); put("-", x, y1) }
            for y in y0...y1 { put("|", x0, y); put("|", x1, y) }
            for (x, y) in [(x0, y0), (x1, y0), (x0, y1), (x1, y1)] { put("+", x, y) }
        }
        // Labels last so borders never overwrite them.
        for (i, z) in zones.enumerated() {
            let label = Array(String(i + 1))
            let cx = clamp(Int(((z.x + z.w / 2) * Double(width)).rounded()) - label.count / 2, width - label.count)
            let cy = clamp(Int(((z.y + z.h / 2) * Double(height)).rounded()), height - 1)
            let y = max(cy, 1)
            for (k, ch) in label.enumerated() { grid[y][cx + k] = ch }
        }
        return grid.map { row -> String in
            var s = String(row)
            while s.hasSuffix(" ") { s.removeLast() }
            return s
        }.joined(separator: "\n")
    }
}
