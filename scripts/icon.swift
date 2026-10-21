import AppKit
let output = CommandLine.arguments[1]
let image = NSImage(size:NSSize(width:1024,height:1024))
image.lockFocus()
let bg = NSBezierPath(roundedRect:NSRect(x:40,y:40,width:944,height:944),xRadius:210,yRadius:210)
NSColor(srgbRed:0.08,green:0.11,blue:0.15,alpha:1).setFill(); bg.fill()
NSColor(srgbRed:0.23,green:0.69,blue:0.93,alpha:1).setStroke()
let plan = NSBezierPath(rect:NSRect(x:270,y:270,width:484,height:484));plan.lineWidth = 32;plan.stroke()
let wall = NSBezierPath();wall.move(to:NSPoint(x:270,y:460));wall.line(to:NSPoint(x:570,y:460));wall.line(to:NSPoint(x:570,y:754));wall.lineWidth = 24;wall.stroke()
NSColor.white.setStroke();let slash = NSBezierPath();slash.move(to:NSPoint(x:200,y:190));slash.line(to:NSPoint(x:814,y:834));slash.lineWidth = 24;slash.stroke()
NSColor(srgbRed:0.93,green:0.68,blue:0.34,alpha:1).setStroke();let arc = NSBezierPath();arc.appendArc(withCenter:NSPoint(x:510,y:270),radius:145,startAngle:0,endAngle:90);arc.lineWidth = 18;arc.stroke()
image.unlockFocus()
var elements = Data()
func word(_ value: UInt32) -> Data { var value = value.bigEndian; return withUnsafeBytes(of:&value) { Data($0) } }
for (kind,px) in [("icp4",16),("icp5",32),("icp6",64),("ic07",128),("ic08",256),("ic09",512),("ic10",1024)] {
        let bitmap = NSBitmapImageRep(bitmapDataPlanes:nil,pixelsWide:px,pixelsHigh:px,bitsPerSample:8,samplesPerPixel:4,hasAlpha:true,isPlanar:false,colorSpaceName:.deviceRGB,bytesPerRow:0,bitsPerPixel:0)!
        NSGraphicsContext.saveGraphicsState();NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep:bitmap)
        image.draw(in:NSRect(x:0,y:0,width:px,height:px));NSGraphicsContext.restoreGraphicsState()
        let png = bitmap.representation(using:.png,properties:[:])!
        elements.append(Data(kind.utf8)); elements.append(word(UInt32(png.count+8))); elements.append(png)
}
var icns = Data("icns".utf8); icns.append(word(UInt32(elements.count+8)));icns.append(elements)
try icns.write(to:URL(fileURLWithPath:output),options:.atomic)
