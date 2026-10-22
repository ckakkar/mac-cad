import AppKit

/// Drafting tools shared by the Tool Sets palette, toolbar, menus and command line.
enum Tool: String, CaseIterable, Identifiable {
    case select, pan, join, explode, breakLine, arrayRect, arrayPolar, block, insert, line, polyline, rectangle, circle, arc, ellipse, spline, polygon, point, text, dimension, alignedDimension, radius, diameter, leader, hatch, erase, move, copy, rotate, scale, mirror, offset, trim, extend, fillet, chamfer, measure
    var id: String { rawValue }

    /// Full name used in menus, tooltips and accessibility.
    var title: String {
        switch self {
        case .alignedDimension: return "Aligned Dimension"
        case .dimension: return "Linear Dimension"
        case .radius: return "Radius Dimension"
        case .diameter: return "Diameter Dimension"
        case .arrayRect: return "Rectangular Array"
        case .arrayPolar: return "Polar Array"
        case .breakLine: return "Break"
        case .block: return "Create Block"
        case .insert: return "Insert Block"
        case .measure: return "Distance"
        default: return rawValue.capitalized
        }
    }
    /// Compact label under a Tool Sets icon.
    var shortTitle: String {
        switch self {
        case .alignedDimension: return "Aligned"
        case .dimension: return "Linear"
        case .radius: return "Radius"
        case .diameter: return "Diameter"
        case .arrayRect: return "Array"
        case .arrayPolar: return "Polar Array"
        case .block: return "Create"
        case .insert: return "Insert"
        default: return title
        }
    }
    /// Familiar keyboard alias, shown in tooltips.
    var alias: String? {
        switch self {
        case .line: return "L"
        case .polyline: return "PL"
        case .rectangle: return "REC"
        case .polygon: return "POL"
        case .circle: return "C"
        case .arc: return "A"
        case .ellipse: return "EL"
        case .spline: return "SPL"
        case .point: return "PO"
        case .text: return "T"
        case .dimension: return "DLI"
        case .alignedDimension: return "DAL"
        case .radius: return "DRA"
        case .diameter: return "DDI"
        case .leader: return "LE"
        case .hatch: return "H"
        case .move: return "M"
        case .copy: return "CO"
        case .rotate: return "RO"
        case .scale: return "SC"
        case .mirror: return "MI"
        case .offset: return "O"
        case .trim: return "TR"
        case .extend: return "EX"
        case .fillet: return "F"
        case .chamfer: return "CHA"
        case .join: return "J"
        case .breakLine: return "BR"
        case .arrayRect: return "AR"
        case .explode: return "X"
        case .erase: return "E"
        case .block: return "B"
        case .insert: return "I"
        case .measure: return "DI"
        case .pan: return "P"
        default: return nil
        }
    }
    var tooltip: String {
        let name = alias.map { "\(title) (\(commandName) · \($0))" } ?? "\(title) (\(commandName))"
        return "\(name)\n\(prompt)"
    }
    var prompt: String {
        switch self {
        case .select: return "Click to add · Shift-click to remove · Return/Space repeats last command"
        case .erase: return "Select objects · Return to erase"
        case .pan: return "Drag to pan · Return/Space or Escape to finish"
        case .join, .explode: return "Select objects · Return to apply"
        case .breakLine: return "Select a line · Pick the break point"
        case .arrayRect, .arrayPolar: return "Select objects · Follow the array prompts"
        case .block: return "Select objects · Enter a name and base point"
        case .insert: return "Enter a block name, insertion point, scale and rotation"
        case .line: return "Specify points · Close/Undo · Space/Return to finish"
        case .polyline: return "Specify vertices · Close/Undo · Space/Return to finish"
        case .rectangle: return "Pick opposite corners"
        case .circle: return "Specify center [2P/3P], then radius/diameter"
        case .arc: return "Specify three points · Center option available"
        case .ellipse: return "Specify major axis endpoints, then minor radius · Center option available"
        case .spline: return "Pick spline control points · Return to finish"
        case .polygon: return "Enter side count, center, construction mode and radius"
        case .point: return "Pick a point"
        case .text: return "Pick the text insertion point"
        case .dimension, .alignedDimension: return "Pick two points, then dimension offset"
        case .radius, .diameter: return "Pick circle center, edge and annotation position"
        case .leader: return "Pick arrow location, then text position"
        case .hatch: return "Pick opposite corners for a rectangular hatch"
        case .move, .copy: return "Select objects before or after starting · Specify base and destination"
        case .rotate: return "Select objects · Pick base point, then enter angle"
        case .scale: return "Select objects · Pick base point, then enter scale factor"
        case .mirror: return "Select objects · Pick two mirror axis points"
        case .offset: return "Enter distance · Select objects · Pick offset side"
        case .trim, .extend: return "Select lines · Pick boundary endpoints, then side to trim/extend"
        case .fillet: return "Enter radius · Select two intersecting lines"
        case .chamfer: return "Enter distances · Select two intersecting lines"
        case .measure: return "Pick two points to measure distance"
        }
    }
    var image: NSImage { CADIcon.image(for: self) }
}

/// Tool Sets palette groups, in AutoCAD for Mac's Drafting tool set order.
enum ToolGroup: String, CaseIterable, Identifiable {
    case draw = "Draw", modify = "Modify", annotation = "Annotation", blocks = "Block"
    var id: String { rawValue }
    var tools: [Tool] {
        switch self {
        case .draw: return [.line, .polyline, .circle, .arc, .rectangle, .polygon, .ellipse, .spline, .point, .hatch]
        case .modify: return [.move, .copy, .rotate, .scale, .mirror, .offset, .trim, .extend, .fillet, .chamfer, .arrayRect, .arrayPolar, .join, .breakLine, .explode, .erase]
        case .annotation: return [.text, .dimension, .alignedDimension, .radius, .diameter, .leader, .measure]
        case .blocks: return [.block, .insert]
        }
    }
}
