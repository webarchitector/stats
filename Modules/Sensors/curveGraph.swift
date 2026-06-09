//
//  curveGraph.swift
//  Sensors
//

import AppKit

public final class CurveGraphView: NSView {
    public var points: [CurvePoint] = [] { didSet { needsDisplay = true } }
    public var maxRPM: Int = 7000 { didSet { needsDisplay = true } }
    public var tempRange: ClosedRange<Double> = 20...100 { didSet { needsDisplay = true } }

    /// Left padding for the Y-axis (RPM) labels.
    private let leftInset: CGFloat = 38
    /// Bottom padding for the X-axis (°C) labels.
    private let bottomInset: CGFloat = 20
    private let topInset: CGFloat = 8
    private let rightInset: CGFloat = 10

    public override var intrinsicContentSize: NSSize {
        // Anchor of the editor — big enough to read the curve at a glance.
        NSSize(width: 320, height: 220)
    }

    public override func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        // Background of the whole view.
        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(bounds)

        let plot = NSRect(
            x: bounds.minX + leftInset,
            y: bounds.minY + bottomInset,
            width: max(0, bounds.width - leftInset - rightInset),
            height: max(0, bounds.height - topInset - bottomInset)
        )
        guard plot.width > 0, plot.height > 0 else { return }

        // Plot area frame.
        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(plot)

        let tempLo = tempRange.lowerBound, tempHi = tempRange.upperBound
        let tempSpan = tempHi - tempLo
        guard tempSpan > 0, maxRPM > 0 else { return }

        // Gridlines + axis labels.
        let gridColor = NSColor.separatorColor.withAlphaComponent(0.4)
        let labelAttrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 9),
            .foregroundColor: NSColor.secondaryLabelColor
        ]
        ctx.setStrokeColor(gridColor.cgColor)
        ctx.setLineWidth(0.5)

        // Y-axis: 4 RPM gridlines + labels.
        let ySteps = 4
        for i in 0...ySteps {
            let frac = CGFloat(i) / CGFloat(ySteps)
            let y = plot.minY + frac * plot.height
            if i > 0 && i < ySteps {
                ctx.move(to: CGPoint(x: plot.minX, y: y))
                ctx.addLine(to: CGPoint(x: plot.maxX, y: y))
                ctx.strokePath()
            }
            let rpm = Int(round(CGFloat(maxRPM) * frac))
            let label = "\(rpm)" as NSString
            let size = label.size(withAttributes: labelAttrs)
            label.draw(at: CGPoint(x: plot.minX - size.width - 4, y: y - size.height / 2),
                       withAttributes: labelAttrs)
        }

        // X-axis: 4 temp gridlines + labels.
        let xSteps = 4
        for i in 0...xSteps {
            let frac = Double(i) / Double(xSteps)
            let x = plot.minX + CGFloat(frac) * plot.width
            if i > 0 && i < xSteps {
                ctx.move(to: CGPoint(x: x, y: plot.minY))
                ctx.addLine(to: CGPoint(x: x, y: plot.maxY))
                ctx.strokePath()
            }
            let temp = Int(round(tempLo + frac * tempSpan))
            let label = "\(temp)°" as NSString
            let size = label.size(withAttributes: labelAttrs)
            label.draw(at: CGPoint(x: x - size.width / 2, y: plot.minY - size.height - 2),
                       withAttributes: labelAttrs)
        }

        guard points.count >= 2 else { return }

        let yScale = plot.height / CGFloat(maxRPM)

        // Filled area under the curve for visual weight.
        ctx.setFillColor(NSColor.systemBlue.withAlphaComponent(0.12).cgColor)
        ctx.beginPath()
        ctx.move(to: CGPoint(x: plot.minX, y: plot.minY))
        for pt in points {
            let xRatio = min(max(0, (pt.tempC - tempLo) / tempSpan), 1)
            let x = plot.minX + CGFloat(xRatio) * plot.width
            let y = plot.minY + CGFloat(pt.rpm) * yScale
            ctx.addLine(to: CGPoint(x: x, y: y))
        }
        ctx.addLine(to: CGPoint(x: plot.maxX, y: plot.minY))
        ctx.closePath()
        ctx.fillPath()

        // Curve line.
        ctx.setStrokeColor(NSColor.systemBlue.cgColor)
        ctx.setLineWidth(2)
        ctx.beginPath()
        for (i, pt) in points.enumerated() {
            let xRatio = min(max(0, (pt.tempC - tempLo) / tempSpan), 1)
            let x = plot.minX + CGFloat(xRatio) * plot.width
            let y = plot.minY + CGFloat(pt.rpm) * yScale
            if i == 0 { ctx.move(to: CGPoint(x: x, y: y)) }
            else      { ctx.addLine(to: CGPoint(x: x, y: y)) }
        }
        ctx.strokePath()

        // Point markers.
        ctx.setFillColor(NSColor.systemBlue.cgColor)
        for pt in points {
            let xRatio = min(max(0, (pt.tempC - tempLo) / tempSpan), 1)
            let x = plot.minX + CGFloat(xRatio) * plot.width
            let y = plot.minY + CGFloat(pt.rpm) * yScale
            ctx.fillEllipse(in: CGRect(x: x - 3.5, y: y - 3.5, width: 7, height: 7))
        }
    }
}
