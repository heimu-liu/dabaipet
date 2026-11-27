import AppKit
import CoreText
import DabaiPetCore
import ImageIO
import UniformTypeIdentifiers

@MainActor public enum BaymaxSnapshot {
    private struct Sample {
        let title: String
        let detail: String
        let state: PetState
        let time: Double
    }

    private static let samples = [
        Sample(title: "待机", detail: "Idle", state: .idle, time: 0),
        Sample(title: "拖动", detail: "vx = +120 pt/s", state: .dragging, time: 0),
        Sample(title: "翻滚蓄力", detail: "t = 0.15 s", state: .rolling(direction: .right), time: 0.15),
        Sample(title: "向右滚出", detail: "t = 0.75 s", state: .rolling(direction: .right), time: 0.75),
        Sample(title: "回滚减速", detail: "t = 1.50 s", state: .rolling(direction: .right), time: 1.50),
        Sample(title: "落稳", detail: "t = 2.00 s", state: .rolling(direction: .right), time: 2.00),
        Sample(title: "戳肚皮", detail: "t = 0.09 s", state: .poked, time: 0.09),
        Sample(title: "倾听", detail: "t = 0.90 s", state: .listening, time: 0.9),
        Sample(title: "开心", detail: "Speaking · Happy", state: .speaking(emotion: .happy), time: 0),
        Sample(title: "关心", detail: "Speaking · Care", state: .speaking(emotion: .care), time: 0),
        Sample(title: "困倦", detail: "Speaking · Sleepy", state: .speaking(emotion: .sleepy), time: 0)
    ]

    public static func write(to url: URL) throws {
        let labelWidth = 144, columnWidth = 440, rowHeight = 258, header = 52
        let width = labelWidth + 4*columnWidth, height = header + rowHeight*samples.count
        let density = 2
        guard let context = CGContext(data: nil, width: width*density, height: height*density,
                                      bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
        else { throw CocoaError(.fileWriteUnknown) }
        context.scaleBy(x: CGFloat(density), y: CGFloat(density))
        context.setFillColor(CGColor(gray: 0.955, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func caption(_ text: String, x: Int, y: Int, size: CGFloat, secondary: Bool = false) {
            let font = CTFontCreateWithName("PingFangSC-Medium" as CFString, size, nil)
            let string = NSAttributedString(string: text, attributes: [
                .init(kCTFontAttributeName as String): font,
                .init(kCTForegroundColorAttributeName as String): CGColor(gray: secondary ? 0.36 : 0.12, alpha: 1)
            ])
            context.textMatrix = .identity
            context.textPosition = CGPoint(x: x, y: y)
            CTLineDraw(CTLineCreateWithAttributedString(string), context)
        }

        let configurations: [(BaymaxScale, DesktopAppearance)] = [
            (.standard, .light), (.standard, .dark), (.large, .light), (.large, .dark)
        ]
        for (column, configuration) in configurations.enumerated() {
            let (scale, appearance) = configuration
            let view = BaymaxLayerView(scale: scale, appearance: appearance)
            let start = CGRect(origin: CGPoint(x: 240, y: 150), size: view.geometry.idleWindowSize)
            guard let plan = ScreenGeometry.wideRollFrame(startFrame: start,
                visibleFrame: CGRect(x: 0, y: 0, width: 1200, height: 800), bodyBounds: view.paintBounds,
                anchor: view.anchor, rollingBodyWidth: view.rollingBodyWidth) else { throw CocoaError(.coderInvalidValue) }
            let left = labelWidth + column*columnWidth
            let label = (scale == .standard ? "1×" : "1.25×") + "   /   " + (appearance == .light ? "白底" : "黑底")
            caption(label, x: left+18, y: height-34, size: 17)
            for (row, sample) in samples.enumerated() {
                let bottom = (samples.count-1-row)*rowHeight
                if column == 0 {
                    caption(sample.title, x: 16, y: bottom+rowHeight/2+2, size: 16)
                    caption(sample.detail, x: 16, y: bottom+rowHeight/2-19, size: 12, secondary: true)
                }
                let cell = CGRect(x: left, y: bottom, width: columnWidth, height: rowHeight)
                context.setFillColor(CGColor(gray: appearance == .light ? 1 : 0, alpha: 1))
                context.fill(cell)
                var canvas = start.size
                var pose = MotionPose()
                var anchor = view.anchor
                switch sample.state {
                case .dragging: pose = MotionEngine.dragging(horizontalVelocity: 120)
                case .poked: pose = MotionEngine.poke(at: sample.time)
                case .rolling:
                    pose = plan.pose(at: sample.time)
                    anchor = plan.anchorInCanvas
                    canvas = plan.wideFrame.size
                default: break
                }
                view.frame.size = canvas
                view.render(pose: pose, at: anchor, state: sample.state, elapsed: sample.time)
                context.saveGState()
                context.translateBy(x: cell.midX - canvas.width/2, y: cell.midY - canvas.height/2)
                view.renderArtwork(in: context)
                context.restoreGState()
            }
        }
        let data = NSMutableData()
        guard let image = context.makeImage(),
              let png = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        else { throw CocoaError(.fileWriteUnknown) }
        CGImageDestinationAddImage(png, image, nil)
        guard CGImageDestinationFinalize(png) else { throw CocoaError(.fileWriteUnknown) }
        try (data as Data).write(to: url, options: .atomic)
    }
}
