import SwiftUI
import AppKit

// MARK: - 顏色

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// 用量階段門檻（0–1）。mid 以上進入第二階段，high 以上進入第三階段。
struct Stages: Equatable {
    var mid: Double
    var high: Double

    static let standard = Stages(mid: 0.5, high: 0.8)

    func isMid(_ f: Double) -> Bool { f >= mid }
    func isHigh(_ f: Double) -> Bool { f >= high }
}

/// 能量波配色：越滿越熱（藍 → 紫 → 橘紅）
struct BeamPalette {
    let tail: Color, mid: Color, core: Color, glow: Color

    static func forLevel(_ f: Double, _ stages: Stages = .standard) -> BeamPalette {
        if stages.isHigh(f) {
            return BeamPalette(tail: Color(hex: 0xB8263F), mid: Color(hex: 0xFF8A3D),
                               core: Color(hex: 0xFFF1C9), glow: Color(hex: 0xFF5A3D))
        }
        if stages.isMid(f) {
            return BeamPalette(tail: Color(hex: 0x5A36D6), mid: Color(hex: 0x9A86FF),
                               core: Color(hex: 0xEFEAFF), glow: Color(hex: 0x8A5CFF))
        }
        return BeamPalette(tail: Color(hex: 0x1D4FD8), mid: Color(hex: 0x38A8FF),
                           core: Color(hex: 0xD4F6FF), glow: Color(hex: 0x3D8BFF))
    }
}

enum Pixel {
    static let bg = Color(hex: 0x0E0F1F)
    static let panel = Color(hex: 0x171A38)
    static let border = Color(hex: 0x2C2F55)
    static let track = Color(hex: 0x22264A)
    static let text = Color(hex: 0xE8ECFF)
    static let sub = Color(hex: 0x8A90C0)
    static func font(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

// MARK: - 像素畫布：把同色像素合併成一條 Path，一次畫完，很省資源

struct PixelCanvas {
    let scale: CGFloat
    private var order: [Color] = []
    private var paths: [Color: Path] = [:]

    init(scale: CGFloat) { self.scale = scale }

    mutating func px(_ x: Double, _ y: Double, _ c: Color, w: Double = 1, h: Double = 1) {
        guard w > 0, h > 0 else { return }
        let rect = CGRect(x: CGFloat(x.rounded()) * scale, y: CGFloat(y.rounded()) * scale,
                          width: CGFloat(w) * scale, height: CGFloat(h) * scale)
        if paths[c] == nil { order.append(c); paths[c] = Path() }
        paths[c]!.addRect(rect)
    }

    mutating func flush(_ ctx: inout GraphicsContext) {
        for c in order {
            if let p = paths[c] {
                ctx.fill(p, with: .color(c), style: FillStyle(antialiased: false))
            }
        }
        order.removeAll()
        paths.removeAll()
    }
}

// MARK: - 原創像素武術家（黑色短髮、炭黑武道服、緋紅衣襟與腰帶）

enum HeroSprite {
    static let rows: [[Character]] = [
        "..........K.K...........",
        ".........KHKHK..........",
        "........KHHHHHHK........",
        ".......KhHHHHHHHK.......",
        "......KhHHHHHSSSK.......",
        "......KHHHHSSSESK.......",
        ".......KHSSSSSSsK.......",
        ".......KKSSSSSsK........",
        "......KjJLSSLJJK........",
        "......KjJJLLJJJK........",
        "......KjJJJLJJjJKKKKKKK.",
        "......KjJJJLJJJJJJJWWSSK",
        "......KJJJJLJJJJJJJWWSSK",
        "......KJJJJLJJjKKKKKKKK.",
        "......KjJJJJJJJK........",
        "......KRRRRRRRRK........",
        "...rRRKRRRRRRRRK........",
        ".rRr.KPPPPPPPPPPK.......",
        "....KPPPpK..KPPPPK......",
        "...KPPPpK....KPPPPK.....",
        "..KPPPpK......KPPPK.....",
        ".KPPPpK.......KPPPK.....",
        "KPPpK.........KPPPK.....",
        "KBBK..........KBBBBK....",
        "Kbb...........KbbbbbK...",
    ].map { Array($0) }

    static let colors: [Character: Color] = [
        "K": Color(hex: 0x07080F),
        "H": Color(hex: 0x15161F), "h": Color(hex: 0x3B3F5C),
        "S": Color(hex: 0xF0C19A), "s": Color(hex: 0xC98F6C), "E": Color(hex: 0x1A1A2E),
        "J": Color(hex: 0x2A2D42), "j": Color(hex: 0x454A68),
        "L": Color(hex: 0xD02A40), "R": Color(hex: 0xD02A40), "r": Color(hex: 0x8E1A2A),
        "W": Color(hex: 0xECE7DA),
        "P": Color(hex: 0x2A2D42), "p": Color(hex: 0x171926),
        "B": Color(hex: 0x3A2F2A), "b": Color(hex: 0x1A1410),
    ]
}

enum HeroRenderer {
    static let W = 150.0
    static let H = 36.0

    static func hash(_ i: Int, _ salt: Double) -> Double {
        let v = sin(Double(i) * 12.9898 + salt * 78.233) * 43758.5453
        return v - floor(v)
    }

    static func draw(_ ctx: inout GraphicsContext, size: CGSize, fraction: Double, time t: Double,
                     stages: Stages = .standard) {
        let f = min(max(fraction, 0), 1)
        let s = min(size.width / CGFloat(W), size.height / CGFloat(H))
        var pc = PixelCanvas(scale: s)
        let p = BeamPalette.forLevel(f, stages)
        let awake = stages.isHigh(f)
        let charged = stages.isMid(f)
        let shake = awake ? sin(t * 40).rounded() : 0
        let oy = 6.0
        let ox = 6.0 + shake
        let sp = 6 + f * 8
        let rows = HeroSprite.rows
        let colors = HeroSprite.colors

        // 1. 衝擊波（60% 以上，85% 以上兩圈）
        if charged {
            let n = awake ? 2 : 1
            for k in 0..<n {
                let ph = (t * 1.2 + Double(k) * 0.5).truncatingRemainder(dividingBy: 1)
                let rad = 4 + ph * 24
                let steps = Int(rad * 4)
                let col = p.glow.opacity((1 - ph) * 0.8)
                for a in 0..<steps {
                    let ang = Double(a) / Double(steps) * 2 * .pi
                    pc.px(ox + 10 + cos(ang) * rad, oy + 16 + sin(ang) * rad * 0.45, col)
                }
            }
            pc.flush(&ctx)
        }

        // 2. 氣場外框
        let aura = p.glow.opacity(awake ? 0.35 : 0.2)
        for (j, row) in rows.enumerated() {
            for (i, c) in row.enumerated() where c != "." && !((c == "R" || c == "r") && i < 6) {
                pc.px(ox + Double(i) - 1, oy + Double(j), aura)
                pc.px(ox + Double(i), oy + Double(j) - 1, aura)
            }
        }
        pc.flush(&ctx)

        // 3. 短髮被氣流往後吹的髮梢
        if f > 0.3 {
            for (k, row) in [1, 2, 3, 4].enumerated() {
                let len = 1 + Int(f * 2.5) - (k % 2)
                guard len > 0, let start = rows[row].firstIndex(where: { $0 != "." }) else { continue }
                for st in 1...len {
                    let y = oy + Double(row) + (sin(t * sp - Double(st) * 0.9 + Double(k)) * 0.7 * f).rounded()
                    pc.px(ox + Double(start) - Double(st), y, st == len ? colors["h"]! : colors["H"]!)
                }
            }
            pc.flush(&ctx)
        }

        // 4. 角色本體
        let lapelGlow: Color? = awake
            ? (Int(t * 6) % 2 == 0 ? Color(hex: 0xFF6B80) : Color(hex: 0xFFB0BC))
            : (charged ? Color(hex: 0xE8485C) : nil)
        for (j, row) in rows.enumerated() {
            for (i, c) in row.enumerated() where c != "." {
                var x = ox + Double(i)
                var y = oy + Double(j)
                var col = colors[c] ?? .clear
                if (c == "R" || c == "r") && i < 6 {          // 腰帶尾端飄動
                    y += (sin(t * (7 + f * 6) + Double(i) * 1.1) * (1 + Double(6 - i) / 3)).rounded()
                    x -= ((1 + f) * 0.6).rounded()
                }
                if c == "L" || c == "R", let g = lapelGlow { col = g }
                if (c == "H" || c == "h") && j <= 3 && f > 0.4 {   // 頭頂髮絲晃動
                    x += (sin(t * sp + Double(j) * 1.3) * (f > 0.75 ? 1.0 : 0.6)).rounded()
                }
                if c == "E" && charged {                        // 眼睛發光
                    col = awake && Int(t * 10) % 3 == 0 ? .white : p.core
                }
                pc.px(x, y, col)
            }
        }
        if awake { pc.px(ox + 12, oy + 5, p.core.opacity(0.6)) }
        pc.flush(&ctx)

        // 5. 地面裂痕與上飄的碎石（85% 以上）
        if awake {
            for k in 0..<5 {
                pc.px(ox + 1 + Double(k) * 4 + hash(k, 3) * 2, oy + 25, Color(white: 0.35), w: 2)
            }
            for k in 0..<9 {
                let ph = (t * 0.8 + hash(k, 1)).truncatingRemainder(dividingBy: 1)
                pc.px(ox - 2 + hash(k, 2) * 26, oy + 25 - ph * 16, Color(white: 0.6).opacity(1 - ph))
            }
            pc.flush(&ctx)
        }

        // 6. 能量波
        let bx = ox + 24
        let by = oy + 10
        let len = ((W - bx - 7) * f).rounded()
        pc.px(bx, by, Pixel.track, w: W - bx - 5, h: 4)
        pc.flush(&ctx)
        if len > 0 {
            let th = awake ? 1.0 : 0
            pc.px(bx, by - 2 - th, p.tail, w: len, h: 8 + th * 2); pc.flush(&ctx)
            pc.px(bx, by - 1, p.mid, w: len, h: 6); pc.flush(&ctx)
            pc.px(bx, by, p.core, w: len, h: 4); pc.flush(&ctx)
            pc.px(bx, by + 1, .white, w: len, h: 2); pc.flush(&ctx)
            for i in 0..<7 {
                let sx = bx + (t * 35 * (1 + Double(i) * 0.3) + Double(i) * 17)
                    .truncatingRemainder(dividingBy: max(len, 1))
                pc.px(sx, by + (i % 2 == 1 ? -2 : 5), p.core, w: 3)
            }
            pc.flush(&ctx)
        }

        // 7. 前端能量球 + 聚集的粒子
        let hx = bx + len
        let r = Double((awake ? 6 : charged ? 5 : 4) + Int(t * 8) % 2)
        for dy in stride(from: -r, through: r, by: 1) {
            for dx in stride(from: -r, through: r, by: 1) {
                let d = dx * dx + dy * dy
                guard d <= r * r else { continue }
                let c: Color = d <= (r - 2) * (r - 2) ? .white : (d <= (r - 1) * (r - 1) ? p.core : p.glow)
                pc.px(hx + dx, by + 2 + dy, c)
            }
        }
        for i in 0..<7 {
            let ph = (t * 1.5 + Double(i) * 0.37).truncatingRemainder(dividingBy: 1)
            let a = Double(i) * 0.9
            let dd = (r + 8) * (1 - ph)
            pc.px(hx + cos(a) * dd, by + 2 + sin(a) * dd * 0.6, p.core)
        }
        pc.flush(&ctx)
    }
}

/// 只有面板打開時才會動畫，關起來不耗資源
struct HeroBeamView: View {
    var fraction: Double
    var stages: Stages = .standard

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { tl in
            Canvas { ctx, size in
                HeroRenderer.draw(&ctx, size: size, fraction: fraction,
                                  time: tl.date.timeIntervalSinceReferenceDate, stages: stages)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: 80)
        .allowsHitTesting(false)
    }
}

// MARK: - 選單列上的迷你像素能量條（靜態圖）

enum MiniBeam {
    static func image(fraction: Double?, stages: Stages = .standard) -> NSImage {
        let f = min(max(fraction ?? 0, 0), 1)
        let p = BeamPalette.forLevel(f, stages)
        let img = NSImage(size: NSSize(width: 30, height: 14), flipped: false) { _ in
            NSGraphicsContext.current?.shouldAntialias = false
            NSColor.labelColor.withAlphaComponent(0.35).setFill()
            NSRect(x: 1, y: 4, width: 24, height: 1).fill()
            NSRect(x: 1, y: 9, width: 24, height: 1).fill()
            NSRect(x: 1, y: 4, width: 1, height: 6).fill()
            NSRect(x: 24, y: 4, width: 1, height: 6).fill()
            let w = (22 * f).rounded()
            if w > 0 {
                NSColor(p.mid).setFill();  NSRect(x: 2, y: 5, width: w, height: 4).fill()
                NSColor(p.core).setFill(); NSRect(x: 2, y: 6, width: w, height: 2).fill()
            }
            let hx = 2 + w
            NSColor(p.glow).setFill();  NSRect(x: hx - 1, y: 3, width: 5, height: 8).fill()
            NSColor.white.setFill();    NSRect(x: hx, y: 5, width: 3, height: 4).fill()
            return true
        }
        img.isTemplate = false
        return img
    }
}
