//
//  curveGraph.swift
//  Sensors
//

import AppKit

public final class CurveGraphView: NSView {
    public var points: [CurvePoint] = [] { didSet { needsDisplay = true } }
    public var maxRPM: Int = 7000 { didSet { needsDisplay = true } }
    public var tempRange: ClosedRange<Double> = 20...100 { didSet { needsDisplay = true } }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let rect = bounds.insetBy(dx: 8, dy: 8)

        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(rect)
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(rect)

        guard points.count >= 2, maxRPM > 0 else { return }

        let tempLo = tempRange.lowerBound, tempHi = tempRange.upperBound
        let tempSpan = tempHi - tempLo
        guard tempSpan > 0 else { return }
        let yScale = rect.height / CGFloat(maxRPM)

        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.beginPath()
        for (i, pt) in points.enumerated() {
            let x = rect.minX + CGFloat((pt.tempC - tempLo) / tempSpan) * rect.width
            let y = rect.minY + CGFloat(pt.rpm) * yScale
            if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) }
            else      { ctx.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.strokePath()

        ctx.setFillColor(NSColor.systemBlue.cgColor)
        for pt in points {
            let x = rect.minX + CGFloat((pt.tempC - tempLo) / tempSpan) * rect.width
            let y = rect.minY + CGFloat(pt.rpm) * yScale
            ctx.fillEllipse(in: CGRect(x: x-3, y: y-3, width: 6, height: 6))
        }
    }
}
