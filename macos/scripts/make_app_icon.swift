// Generates HanLens/Resources/AppIcon.icon, the app icon in macOS 26's layered Icon Composer format: a white glass
// magnifier over a gold 汉 on Chinese red. The system masks it to the icon shape and adds the Liquid Glass
// lighting, plus dark, clear and tinted variants.
// Usage: swift scripts/make_app_icon.swift HanLens/Resources/AppIcon.icon
import AppKit
import CoreText

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("usage: make_app_icon.swift <AppIcon.icon>\n".utf8))
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = output.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: output)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)

// Geometry on the 1024 pt canvas (SVG coordinates: origin top left, y down). The lens sits up and to the left so
// the magnifier as a whole, handle included, is centred.
let canvas = 1024.0
let lens = CGPoint(x: 430, y: 430)
let ringRadius = 288.0      // centre line of the rim
let rimWidth = 78.0
let handleStart = 300.0     // distance from the lens centre along the diagonal
let handleEnd = 640.0
let handleWidth = 128.0
let glyphHeight = 316.0

func svg(_ body: String) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="\(Int(canvas))" height="\(Int(canvas))" viewBox="0 0 \(Int(canvas)) \(Int(canvas))">
    \(body)
    </svg>

    """
}

func format(_ value: CGFloat) -> String { String(format: "%.2f", value) }

/// The outline of one character in SVG path syntax, scaled to `height` and centred on `center`.
func glyphPath(_ character: String, fontName: String, height: CGFloat, center: CGPoint) -> String {
    let font = CTFontCreateWithName(fontName as CFString, 1000, nil)
    var characters = Array(character.utf16)
    var glyphs = [CGGlyph](repeating: 0, count: characters.count)
    guard CTFontGetGlyphsForCharacters(font, &characters, &glyphs, characters.count),
          let path = CTFontCreatePathForGlyph(font, glyphs[0], nil) else {
        fatalError("\(fontName) has no glyph for \(character)")
    }
    let box = path.boundingBoxOfPath
    let scale = height / box.height
    // Font units are y-up; flip into SVG space and centre the outline's bounding box.
    func point(_ p: CGPoint) -> String {
        let x = center.x + (p.x - box.midX) * scale
        let y = center.y - (p.y - box.midY) * scale
        return "\(format(x)) \(format(y))"
    }
    var data = ""
    path.applyWithBlock { element in
        let points = element.pointee.points
        switch element.pointee.type {
        case .moveToPoint: data += "M\(point(points[0]))"
        case .addLineToPoint: data += "L\(point(points[0]))"
        case .addQuadCurveToPoint: data += "Q\(point(points[0])) \(point(points[1]))"
        case .addCurveToPoint: data += "C\(point(points[0])) \(point(points[1])) \(point(points[2]))"
        case .closeSubpath: data += "Z"
        @unknown default: break
        }
    }
    return data
}

let diagonal = CGPoint(x: cos(Double.pi / 4), y: sin(Double.pi / 4))
func along(_ distance: Double) -> CGPoint { CGPoint(x: lens.x + diagonal.x * distance, y: lens.y + diagonal.y * distance) }
let start = along(handleStart), end = along(handleEnd)

let layers: [(file: String, body: String)] = [
    ("glyph.svg", "<path fill=\"#FFD45E\" fill-rule=\"nonzero\" d=\"\(glyphPath("汉", fontName: "PingFangSC-Semibold", height: glyphHeight, center: lens))\"/>"),
    ("magnifier.svg", """
    <circle cx="\(format(lens.x))" cy="\(format(lens.y))" r="\(format(ringRadius))" fill="none" stroke="#FFFFFF" stroke-width="\(format(rimWidth))"/>
    <line x1="\(format(start.x))" y1="\(format(start.y))" x2="\(format(end.x))" y2="\(format(end.y))" stroke="#FFFFFF" stroke-width="\(format(handleWidth))" stroke-linecap="round"/>
    """),
    ("lens.svg", "<circle cx=\"\(format(lens.x))\" cy=\"\(format(lens.y))\" r=\"\(format(ringRadius))\" fill=\"#FFFFFF\" fill-opacity=\"0.22\"/>"),
]
for layer in layers {
    try svg(layer.body).write(to: assets.appendingPathComponent(layer.file), atomically: true, encoding: .utf8)
}

// Groups run front to back.
let icon: [String: Any] = [
    "color-space-for-untagged-svg-colors": "display-p3",
    "fill": [
        "linear-gradient": ["display-p3:0.93000,0.30000,0.22000,1.00000", "display-p3:0.70000,0.09000,0.16000,1.00000"],
        "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 0.75]],
    ],
    "fill-specializations": [
        ["value": "automatic"],
        ["appearance": "dark", "value": [
            "linear-gradient": ["display-p3:0.36000,0.07000,0.09000,1.00000", "display-p3:0.16000,0.03000,0.05000,1.00000"],
            "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 0.75]],
        ]],
    ],
    "groups": [
        [
            "layers": [["image-name": "glyph.svg", "name": "glyph", "glass": false]],
            "shadow": ["kind": "layer-color", "opacity": 0.45],
            "translucency": ["enabled": false, "value": 0],
            "specular": true,
        ],
        [
            "layers": [["image-name": "magnifier.svg", "name": "magnifier", "glass": true]],
            "shadow": ["kind": "neutral", "opacity": 0.5],
            "translucency": ["enabled": true, "value": 0.15],
            "specular": true,
        ],
        [
            "layers": [["image-name": "lens.svg", "name": "lens", "glass": true]],
            "blur-material": 0.5,
            "shadow": ["kind": "none", "opacity": 0],
            "translucency": ["enabled": true, "value": 0.6],
        ],
    ],
    "supported-platforms": ["squares": ["macOS"]],
]
let json = try JSONSerialization.data(withJSONObject: icon, options: [.prettyPrinted, .sortedKeys])
try json.write(to: output.appendingPathComponent("icon.json"))
print("Wrote \(output.path)")
