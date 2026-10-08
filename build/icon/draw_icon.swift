import AppKit

// 本地绘制 FileReorg 应用图标（1024×1024，Big Sur 风格：824 圆角底板 + 内容边距 100）
let S: CGFloat = 1024
let image = NSImage(size: NSSize(width: S, height: S))
image.lockFocusFlipped(true)

func rr(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ r: CGFloat) -> NSBezierPath {
    NSBezierPath(roundedRect: NSRect(x: x, y: y, width: w, height: h), xRadius: r, yRadius: r)
}

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: alpha)
}

func setShadow(_ alpha: CGFloat, _ offsetY: CGFloat, _ blur: CGFloat) {
    let sh = NSShadow()
    sh.shadowColor = NSColor.black.withAlphaComponent(alpha)
    sh.shadowOffset = NSSize(width: 0, height: offsetY)  // flipped 坐标系：正值向下
    sh.shadowBlurRadius = blur
    sh.set()
}

func vGradient(_ path: NSBezierPath, _ top: NSColor, _ bottom: NSColor) {
    path.addClip()
    NSGradient(starting: top, ending: bottom)!.draw(
        from: NSPoint(x: path.bounds.midX, y: path.bounds.minY),
        to: NSPoint(x: path.bounds.midX, y: path.bounds.maxY),
        options: [.drawsBeforeStartingLocation, .drawsAfterEndingLocation])
}

// MARK: 1) 底板（带投影 + 渐变 + 顶部高光描边）
let tile = rr(100, 100, 824, 824, 184)
NSGraphicsContext.saveGraphicsState()
setShadow(0.30, 16, 44)
color(0x1560D0).setFill()
tile.fill()
NSGraphicsContext.restoreGraphicsState()

NSGraphicsContext.saveGraphicsState()
vGradient(tile, color(0x57ADFF), color(0x1560D0))
NSGraphicsContext.restoreGraphicsState()

let inset = rr(103, 103, 818, 818, 181)
inset.lineWidth = 4
NSColor.white.withAlphaComponent(0.16).setStroke()
inset.stroke()

// MARK: 2) 内容坐标系（824 底板内铺 1024 设计稿）
let t = NSAffineTransform()
t.translateX(by: 100, yBy: 100)
t.scaleX(by: 0.805, yBy: 0.805)
t.concat()

// 文件夹背板（含标签页）
NSGraphicsContext.saveGraphicsState()
setShadow(0.28, 14, 30)
let back = NSBezierPath()
back.append(rr(112, 252, 344, 128, 40))
back.append(rr(112, 322, 800, 448, 46))
color(0x2F79DE).setFill()
back.fill()
NSGraphicsContext.restoreGraphicsState()

// 白色文档（从背板探出）
NSGraphicsContext.saveGraphicsState()
setShadow(0.18, 8, 18)
let doc = rr(468, 178, 300, 280, 22)
NSColor.white.setFill()
doc.fill()
NSGraphicsContext.restoreGraphicsState()
doc.lineWidth = 3
color(0xC9D9EE).setStroke()
doc.stroke()
let rules = NSBezierPath()
rules.lineWidth = 11
rules.lineCapStyle = .round
rules.move(to: NSPoint(x: 512, y: 258)); rules.line(to: NSPoint(x: 724, y: 258))
rules.move(to: NSPoint(x: 512, y: 308)); rules.line(to: NSPoint(x: 724, y: 308))
rules.move(to: NSPoint(x: 512, y: 358)); rules.line(to: NSPoint(x: 668, y: 358))
color(0xA9BDD9).setStroke()
rules.stroke()

// 文件夹前板（浅色渐变）
NSGraphicsContext.saveGraphicsState()
setShadow(0.15, 6, 16)
color(0xD3E5FF).setFill()
rr(112, 382, 800, 388, 46).fill()
NSGraphicsContext.restoreGraphicsState()
NSGraphicsContext.saveGraphicsState()
let front = rr(112, 382, 800, 388, 46)
vGradient(front, color(0xFAFCFF), color(0xD3E5FF))
NSGraphicsContext.restoreGraphicsState()

// 年份标签（归档语义）
func chip(_ x: CGFloat, _ label: String) {
    let rect = rr(x, 806, 200, 92, 28)
    NSGraphicsContext.saveGraphicsState()
    setShadow(0.25, 8, 20)
    NSColor.white.setFill()
    rect.fill()
    NSGraphicsContext.restoreGraphicsState()
    let para = NSMutableParagraphStyle()
    para.alignment = .center
    let attrs: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 56, weight: .bold),
        .foregroundColor: color(0x1560D0),
        .paragraphStyle: para,
    ]
    let size = (label as NSString).size(withAttributes: attrs)
    (label as NSString).draw(
        at: NSPoint(x: x + 100 - size.width / 2, y: 806 + 46 - size.height / 2),
        withAttributes: attrs)
}
chip(300, "2023")
chip(524, "2024")

// MARK: 3) 输出 PNG
image.unlockFocus()
let rep = NSBitmapImageRep(data: image.tiffRepresentation!)!
let png = rep.representation(using: .png, properties: [:])!
try! png.write(to: URL(fileURLWithPath: CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "master.png"))
print("icon written")
