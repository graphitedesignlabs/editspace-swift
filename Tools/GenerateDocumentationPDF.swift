#!/usr/bin/env swift

import AppKit
import CoreGraphics
import Foundation

let repository = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let sourceURL = repository.appendingPathComponent("Docs/EditSpace-System-and-API.md")
let outputURL = repository.appendingPathComponent("Docs/EditSpace-System-and-API.pdf")
let markdown = try String(contentsOf: sourceURL, encoding: .utf8)

let pageWidth: CGFloat = 612
let pageHeight: CGFloat = 792
let margin: CGFloat = 54
let contentWidth = pageWidth - (margin * 2)
var mediaBox = CGRect(x: 0, y: 0, width: pageWidth, height: pageHeight)

guard let consumer = CGDataConsumer(url: outputURL as CFURL),
      let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else {
    fatalError("Unable to create PDF context")
}

let bodyStyle = NSMutableParagraphStyle()
bodyStyle.lineSpacing = 3
bodyStyle.paragraphSpacing = 7
let listStyle = bodyStyle.mutableCopy() as! NSMutableParagraphStyle
listStyle.firstLineHeadIndent = 0
listStyle.headIndent = 16

let bodyAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.systemFont(ofSize: 10.5),
    .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1),
    .paragraphStyle: bodyStyle
]
let codeAttributes: [NSAttributedString.Key: Any] = [
    .font: NSFont.monospacedSystemFont(ofSize: 8.5, weight: .regular),
    .foregroundColor: NSColor(calibratedWhite: 0.12, alpha: 1)
]

var y: CGFloat = margin
var pageNumber = 0

func beginPage() {
    context.beginPDFPage(nil)
    context.saveGState()
    context.translateBy(x: 0, y: pageHeight)
    context.scaleBy(x: 1, y: -1)
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
    pageNumber += 1
    y = margin
}

func endPage() {
    let footer = NSAttributedString(
        string: "EditSpace System and API  •  \(pageNumber)",
        attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.gray]
    )
    footer.draw(at: CGPoint(x: margin, y: pageHeight - 31))
    NSGraphicsContext.current = nil
    context.restoreGState()
    context.endPDFPage()
}

func ensureSpace(_ height: CGFloat) {
    if y + height > pageHeight - margin {
        endPage()
        beginPage()
    }
}

func drawText(_ text: String, attributes: [NSAttributedString.Key: Any], spacingAfter: CGFloat = 7) {
    let attributed = NSAttributedString(string: text, attributes: attributes)
    let bounds = attributed.boundingRect(
        with: CGSize(width: contentWidth, height: 10_000),
        options: [.usesLineFragmentOrigin, .usesFontLeading]
    )
    let height = ceil(bounds.height)
    ensureSpace(height + spacingAfter)
    attributed.draw(with: CGRect(x: margin, y: y, width: contentWidth, height: height), options: [.usesLineFragmentOrigin, .usesFontLeading])
    y += height + spacingAfter
}

func drawBox(_ rect: CGRect, title: String, detail: String, color: NSColor) {
    color.setFill()
    NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9).fill()
    NSColor(calibratedWhite: 0.35, alpha: 1).setStroke()
    let border = NSBezierPath(roundedRect: rect, xRadius: 9, yRadius: 9)
    border.lineWidth = 1
    border.stroke()
    let titleString = NSAttributedString(string: title, attributes: [.font: NSFont.boldSystemFont(ofSize: 10), .foregroundColor: NSColor.black])
    let detailString = NSAttributedString(string: detail, attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.darkGray])
    titleString.draw(at: CGPoint(x: rect.midX - titleString.size().width / 2, y: rect.minY + 14))
    detailString.draw(at: CGPoint(x: rect.midX - detailString.size().width / 2, y: rect.minY + 34))
}

func drawArrow(from start: CGPoint, to end: CGPoint) {
    NSColor(calibratedRed: 0.42, green: 0.29, blue: 0.82, alpha: 1).setStroke()
    let path = NSBezierPath()
    path.move(to: start)
    path.line(to: end)
    path.lineWidth = 1.8
    path.stroke()
    let angle = atan2(end.y - start.y, end.x - start.x)
    let head = NSBezierPath()
    head.move(to: end)
    head.line(to: CGPoint(x: end.x - 7 * cos(angle - .pi / 6), y: end.y - 7 * sin(angle - .pi / 6)))
    head.move(to: end)
    head.line(to: CGPoint(x: end.x - 7 * cos(angle + .pi / 6), y: end.y - 7 * sin(angle + .pi / 6)))
    head.lineWidth = 1.8
    head.stroke()
}

func drawArchitecture() {
    let height: CGFloat = 330
    ensureSpace(height + 12)
    let top = y + 12
    drawBox(CGRect(x: margin + 102, y: top, width: 300, height: 62), title: "EditSpace protocol specification", detail: "Language-neutral contract and convergence rules", color: NSColor(calibratedRed: 1, green: 0.95, blue: 0.86, alpha: 1))
    drawBox(CGRect(x: margin + 16, y: top + 112, width: 200, height: 66), title: "EditSpace Swift", detail: "Reference implementation", color: NSColor(calibratedRed: 0.94, green: 0.91, blue: 1, alpha: 1))
    drawBox(CGRect(x: margin + 288, y: top + 112, width: 200, height: 66), title: "EditSpace Python", detail: "Independent implementation", color: NSColor(calibratedRed: 0.90, green: 0.97, blue: 0.93, alpha: 1))
    drawArrow(from: CGPoint(x: margin + 210, y: top + 62), to: CGPoint(x: margin + 116, y: top + 112))
    drawArrow(from: CGPoint(x: margin + 294, y: top + 62), to: CGPoint(x: margin + 388, y: top + 112))
    let defines = NSAttributedString(string: "defines", attributes: [.font: NSFont.systemFont(ofSize: 8), .foregroundColor: NSColor.gray])
    defines.draw(at: CGPoint(x: margin + 151, y: top + 82))
    defines.draw(at: CGPoint(x: margin + 326, y: top + 82))
    drawArrow(from: CGPoint(x: margin + 216, y: top + 137), to: CGPoint(x: margin + 288, y: top + 137))
    drawArrow(from: CGPoint(x: margin + 288, y: top + 155), to: CGPoint(x: margin + 216, y: top + 155))
    let wire = NSAttributedString(string: "same wire protocol", attributes: [.font: NSFont.systemFont(ofSize: 7.5), .foregroundColor: NSColor.gray])
    wire.draw(at: CGPoint(x: margin + 218, y: top + 123))
    drawBox(CGRect(x: margin + 16, y: top + 242, width: 200, height: 62), title: "Graphite", detail: "imports EditSpace Swift", color: NSColor(calibratedRed: 0.90, green: 0.94, blue: 1, alpha: 1))
    drawBox(CGRect(x: margin + 288, y: top + 242, width: 200, height: 62), title: "Blender plug-in", detail: "imports EditSpace Python", color: NSColor(calibratedRed: 0.90, green: 0.94, blue: 1, alpha: 1))
    drawArrow(from: CGPoint(x: margin + 116, y: top + 242), to: CGPoint(x: margin + 116, y: top + 178))
    drawArrow(from: CGPoint(x: margin + 388, y: top + 242), to: CGPoint(x: margin + 388, y: top + 178))
    y += height
}

func drawSyncFlow() {
    let height: CGFloat = 190
    ensureSpace(height + 12)
    let top = y + 8
    let boxes = ["Native edit", "Append locally", "Queue + transmit", "Materialize"]
    for (index, label) in boxes.enumerated() {
        let x = margin + CGFloat(index) * 128
        drawBox(CGRect(x: x, y: top, width: 112, height: 52), title: label, detail: index == 1 ? "immutable" : "durable path", color: NSColor(calibratedRed: 0.94, green: 0.95, blue: 0.98, alpha: 1))
        if index < boxes.count - 1 { drawArrow(from: CGPoint(x: x + 112, y: top + 26), to: CGPoint(x: x + 128, y: top + 26)) }
    }
    drawBox(CGRect(x: margin + 70, y: top + 100, width: 155, height: 52), title: "Presence update", detail: "identity • selection • TTL", color: NSColor(calibratedRed: 1, green: 0.96, blue: 0.88, alpha: 1))
    drawBox(CGRect(x: margin + 285, y: top + 100, width: 155, height: 52), title: "Optional endpoint UI", detail: "never document state", color: NSColor(calibratedRed: 1, green: 0.96, blue: 0.88, alpha: 1))
    drawArrow(from: CGPoint(x: margin + 225, y: top + 126), to: CGPoint(x: margin + 285, y: top + 126))
    y += height
}

beginPage()
var inFrontMatter = false
var frontMatterStarted = false
var inCode = false
var paragraph: [String] = []

func flushParagraph() {
    guard !paragraph.isEmpty else { return }
    drawText(paragraph.joined(separator: " "), attributes: inCode ? codeAttributes : bodyAttributes, spacingAfter: inCode ? 10 : 7)
    paragraph.removeAll()
}

for line in markdown.components(separatedBy: .newlines) {
    if line == "---" {
        if !frontMatterStarted {
            frontMatterStarted = true
            inFrontMatter = true
        }
        else if inFrontMatter { inFrontMatter = false }
        continue
    }
    if inFrontMatter { continue }
    if line.hasPrefix("```") { flushParagraph(); inCode.toggle(); continue }
    if line.hasPrefix("![") {
        flushParagraph()
        if line.contains("architecture.") { drawArchitecture() }
        else if line.contains("sync-flow.") { drawSyncFlow() }
        continue
    }
    if line.hasPrefix("#") {
        flushParagraph()
        let level = line.prefix { $0 == "#" }.count
        let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
        let size: CGFloat = level == 1 ? 24 : level == 2 ? 17 : 13
        let color = level == 1 ? NSColor(calibratedRed: 0.20, green: 0.12, blue: 0.43, alpha: 1) : NSColor(calibratedWhite: 0.12, alpha: 1)
        drawText(title, attributes: [.font: NSFont.boldSystemFont(ofSize: size), .foregroundColor: color], spacingAfter: level == 1 ? 13 : 8)
        continue
    }
    if line.isEmpty { flushParagraph(); continue }
    if line.hasPrefix("- ") || line.range(of: #"^\d+\. "#, options: .regularExpression) != nil {
        flushParagraph()
        let text = line.hasPrefix("- ") ? "• " + line.dropFirst(2) : line
        drawText(String(text), attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor(calibratedWhite: 0.15, alpha: 1), .paragraphStyle: listStyle], spacingAfter: 3)
        continue
    }
    paragraph.append(line)
}
flushParagraph()
endPage()
context.closePDF()
print("Generated \(outputURL.path)")
