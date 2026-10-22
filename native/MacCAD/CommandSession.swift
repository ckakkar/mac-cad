import Foundation

/// Transient prompts only. Rust remains the owner of geometry, selection and undo.
struct CommandSession {
    enum Stage { case idle, selection, points, polygonSides, polygonMode, radius, angle, factor, distance, offsetSide, filletRadius, chamferFirst, chamferSecond, textHeight, textRotation, textValue, mirrorDelete, zoom, values, blockName, insertName, insertScale, insertAngle }
    enum Effect {
        case command(String), undoLine(UInt64), add([String:Any]), clearSelection, selectAll, selectLast, selectPrevious
        case fit, zoom(Double), zoomWindow(CADBounds), previousView, measure(CADPoint,CADPoint)
    }
    var tool: Tool = .select
    var stage: Stage = .idle
    var name = ""
    var points: [CADPoint] = []
    var lineRevisions:[UInt64] = []
    var defaults = Defaults()
    struct Defaults {
        var radius = 100.0, distance = 100.0, fillet = 0.0, chamferA = 100.0, chamferB = 100.0
        var sides = 4, height = 150.0, rotation = 0.0
    }
    var value = 0.0
    var parameters:[Double] = []
    var circlePoints = 0
    var diameter = false
    var centerMode = false
    var circumscribed = false
    var closed = false
    var text = ""
    var active: Bool { stage != .idle }
    var selecting: Bool { stage == .selection }
    var acceptsSpaces: Bool { stage == .textValue }
    var base: CADPoint? { points.last }
    var prompt: String {
        switch stage {
        case .idle: return "Command:"
        case .selection: return "\(name) Select objects [All/Last/Previous] · Return to accept:"
        case .polygonSides: return "POLYGON Number of sides <\(defaults.sides)>:"
        case .polygonMode: return "POLYGON [Inscribed/Circumscribed] <\(circumscribed ? "C" : "I")>:"
        case .radius: return "CIRCLE \(diameter ? "Diameter" : "Radius [Diameter]") <\(diameter ? defaults.radius*2:defaults.radius)>:"
        case .angle: return "ROTATE Angle <0>:"
        case .factor: return "SCALE Positive scale factor <1>:"
        case .distance: return "OFFSET Distance <\(defaults.distance)>:"
        case .offsetSide: return "OFFSET Specify point on side to offset · Return to finish:"
        case .filletRadius: return "FILLET Radius <\(defaults.fillet)>:"
        case .chamferFirst: return "CHAMFER First distance <\(defaults.chamferA)>:"
        case .chamferSecond: return "CHAMFER Second distance <\(defaults.chamferB)>:"
        case .textHeight: return "\(name) Text height <\(defaults.height)>:"
        case .textRotation: return "\(name) Rotation <\(defaults.rotation)>:"
        case .textValue: return "\(name) Enter text (spaces insert text; Return completes):"
        case .mirrorDelete: return "MIRROR Erase source objects? [Yes/No] <No>:"
        case .zoom: return "ZOOM [Extents/Window/Previous] or scale factor:"
        case .blockName:return "BLOCK Enter new block name (one word):"
        case .insertName:return "INSERT Enter block name (one word):"
        case .insertScale:return "INSERT Scale <1>:"
        case .insertAngle:return "INSERT Rotation <0>:"
        case .values:
            let labels = tool == .arrayRect ? ["Rows <2>","Columns <2>","Column spacing <100>","Row spacing <100>"]:["Number of items <6>","Angle to fill <360>"]
            return name+" "+labels[min(parameters.count,labels.count-1)]+":"
        case .points:
            switch tool {
            case .line, .polyline, .spline:
                return "\(name) \(points.isEmpty ? "Specify first point" : "Specify next point [Close/Undo]") · Return to finish:"
            case .move, .copy: return "\(name) \(points.isEmpty ? "Specify base point" : "Specify second point") · Return to finish:"
            case .rotate, .scale: return "\(name) Specify base point:"
            case .pan:return "PAN Drag to pan · Return/Space to finish:"
            case .circle: return "CIRCLE \(points.isEmpty && circlePoints == 0 ? "Specify center [2P/3P]" : "Specify point \(points.count+1)"):"
            case .arc: return "ARC \(points.isEmpty ? "Specify start point [Center]" : "Specify point \(points.count+1)"):"
            case .ellipse: return "ELLIPSE \(points.isEmpty ? "Specify axis endpoint [Center]" : points.count == 1 ? "Specify other axis endpoint" : "Specify minor radius"):"
            case .polygon: return "POLYGON Specify center:"
            case .text: return "\(name) Specify insertion point:"
            default: return "\(name) Specify point \(points.count+1):"
            }
        }
    }
    mutating func reset() { tool = .select; stage = .idle; name = ""; points = [];parameters = [];lineRevisions = [] }
    mutating func start(_ tool:Tool, name:String, selected:Int) -> [Effect] {
        reset(); self.tool = tool; self.name = name
        circlePoints = 0; diameter = false; centerMode = false; circumscribed = false; closed = false
        switch tool {
        case .select: return []
        case .polygon: stage = .polygonSides
        case .offset: stage = .distance
        case .fillet: stage = .filletRadius
        case .chamfer: stage = .chamferFirst
        case .erase, .join, .explode:
            if selected>0 {let c = name;reset();return [.command(c),.clearSelection]};stage = .selection
        case .arrayRect:stage = selected>0 ? .values:.selection
        case .block:stage = selected>0 ? .blockName:.selection
        case .insert:stage = .insertName
        default: stage = tool.requiresSelection && selected == 0 ? .selection : .points
        }
        return []
    }
    mutating func startZoom() { reset();name = "ZOOM"; stage = .zoom }
    mutating func respond(_ raw:String, cursor:CADPoint, selected:Int) throws -> [Effect] {
        let input = raw.trimmingCharacters(in:.whitespacesAndNewlines)
        let word = input.uppercased()
        if stage == .textValue {
            guard !input.isEmpty else { reset();return [] }
            if tool == .leader {
                let command = "LEADER \(points[0].command) \(points[1].command) \(defaults.height) \(raw)"
                reset();return [.command(command)]
            }
            let shape:[String:Any] = ["kind":"text","at":points[0].json,"text":raw.replacingOccurrences(of:"\\P",with:"\n"),"height":defaults.height,"rotation":defaults.rotation * .pi/180]
            reset();return [.add(shape)]
        }
        if stage == .blockName || stage == .insertName {
            guard !input.isEmpty,!input.contains(where:{$0.isWhitespace}),!input.hasPrefix("*") else{throw CoreError.message("Enter a nonempty block name without spaces or an initial asterisk")}
            text = input;stage = .points;return []
        }
        if stage == .selection {
            if ["A","ALL"].contains(word) { return [.selectAll] }
            if ["L","LAST"].contains(word) { return [.selectLast] }
            if ["P","PREVIOUS"].contains(word) { return [.selectPrevious] }
            guard input.isEmpty else { throw CoreError.message("Select objects on the canvas, or enter All, Last or Previous") }
            guard selected > 0 else { throw CoreError.message("No editable objects selected") }
            if [.erase,.join,.explode].contains(tool) {let c = name;reset();return [.command(c),.clearSelection]}
            if tool == .arrayRect {stage = .values;return []}
            if tool == .block {stage = .blockName;return []}
            if name == "SELECT" {reset();return []}
            if tool == .offset {stage = .offsetSide;return []}
            if tool == .fillet { let c = "FILLET \(defaults.fillet)";reset();return [.command(c),.clearSelection] }
            if tool == .chamfer { let c = "CHAMFER \(defaults.chamferA) \(defaults.chamferB)";reset();return [.command(c),.clearSelection] }
            stage = .points;return []
        }
        if stage == .zoom {
            if ["","E","EXTENTS","A","ALL"].contains(word) { reset();return [.fit] }
            if ["W","WINDOW"].contains(word) {stage = .points;return []}
            if ["P","PREVIOUS"].contains(word) {reset();return [.previousView]}
            let token = word.hasSuffix("X") ? String(word.dropLast()):word
            guard let n = Double(token),n.isFinite,n>0 else {throw CoreError.message("Choose Extents, Window, Previous or a positive zoom factor")}
            reset();return [.zoom(n)]
        }
        if stage == .mirrorDelete {
            guard ["","N","NO","Y","YES"].contains(word) else {throw CoreError.message("Enter Yes or No")}
            let c = "MIRROR \(points[0].command) \(points[1].command) \(word.hasPrefix("Y") ? "delete" : "keep")"
            reset();return [.command(c),.clearSelection]
        }
        if [.polygonSides,.polygonMode,.distance,.filletRadius,.chamferFirst,.chamferSecond,.textHeight,.textRotation,.angle,.factor,.radius,.values,.insertScale,.insertAngle].contains(stage) {
            if stage == .polygonMode {
                guard ["","I","INSCRIBED","C","CIRCUMSCRIBED"].contains(word) else {throw CoreError.message("Choose Inscribed or Circumscribed")}
                circumscribed = word.hasPrefix("C");stage = .points;return []
            }
            if stage == .radius && ["D","DIAMETER"].contains(word) {diameter = true;return []}
            if let p = Self.coordinate(input,base:base) {return try point(p,selected:selected)}
            let fallback:Double
            switch stage {
            case .polygonSides: fallback = Double(defaults.sides)
            case .distance: fallback = defaults.distance
            case .filletRadius: fallback = defaults.fillet
            case .chamferFirst: fallback = defaults.chamferA
            case .chamferSecond: fallback = defaults.chamferB
            case .textHeight: fallback = defaults.height
            case .textRotation: fallback = defaults.rotation
            case .radius: fallback = defaults.radius*(diameter ? 2:1)
            case .factor,.insertScale: fallback = 1
            case .values: fallback = tool == .arrayRect ? [2,2,100,100][min(parameters.count,3)]:[6,360][min(parameters.count,1)]
            default: fallback = 0
            }
            guard let n = input.isEmpty ? fallback:Double(input),n.isFinite else {throw CoreError.message("Enter a finite numeric value")}
            return try scalar(n,selected:selected)
        }
        if input.isEmpty {
            if stage == .offsetSide || tool == .line || tool == .copy {reset();return [.clearSelection]}
            if tool == .polyline || tool == .spline {
                if points.count >= 2 {let c = "\(name) "+points.map(\.command).joined(separator:" ");reset();return [.command(c)]}
                reset();return []
            }
            reset();return [.clearSelection]
        }
        if ["U","UNDO"].contains(word),[.line,.polyline,.spline].contains(tool) {
            guard points.count > 1 else {throw CoreError.message("No segment to undo in this command")}
            if tool == .line {
                guard let revision = lineRevisions.last else {throw CoreError.message("No line segment to undo")}
                points.removeLast();lineRevisions.removeLast();return [.undoLine(revision)]
            }
            points.removeLast();return []
        }
        if ["C","CLOSE"].contains(word),[.line,.polyline].contains(tool) {
            guard points.count >= 3 else {throw CoreError.message("Close needs at least three points")}
            let c = tool == .line ? "LINE \(points.last!.command) \(points[0].command)":"PLINE "+points.map(\.command).joined(separator:" ")+" close"
            reset();return [.command(c)]
        }
        if tool == .circle && points.isEmpty && ["2P","3P"].contains(word) {circlePoints = word == "2P" ? 2:3;return []}
        if [.arc,.ellipse].contains(tool) && points.isEmpty && ["C","CENTER"].contains(word) {centerMode = true;return []}
        if let p = Self.coordinate(input,base:base) {return try point(p,selected:selected)}
        if let n = Double(input),n.isFinite {return try scalar(n,selected:selected,cursor:cursor)}
        throw CoreError.message("Expected a coordinate, distance or displayed command option")
    }
    mutating func scalar(_ n:Double,selected:Int,cursor:CADPoint? = nil) throws -> [Effect] {
        guard n.isFinite else {throw CoreError.message("Enter a finite number")}
        switch stage {
        case .insertScale:
            guard n>0 else{throw CoreError.message("Insert scale must be positive")};value = n;stage = .insertAngle
        case .insertAngle:
            let c = "INSERT \(text) \(points[0].command) \(value) \(n)";reset();return [.command(c)]
        case .values:
            if parameters.count < (tool == .arrayRect ? 2:1) {guard n.rounded() == n,n>=1,n<=10000 else{throw CoreError.message("Array counts must be integers from 1 to 10000")}}
            if tool == .arrayPolar,parameters.count == 1 {guard n != 0,abs(n)<=360 else{throw CoreError.message("Array angle must be nonzero and no greater than 360 degrees")}}
            parameters.append(n)
            if tool == .arrayRect,parameters.count == 4 {let c = "ARRAYRECT "+parameters.map{String($0)}.joined(separator:" ");reset();return [.command(c),.clearSelection]}
            if tool == .arrayPolar,parameters.count == 2 {let c = "ARRAYPOLAR \(points[0].command) \(parameters[0]) \(parameters[1])";reset();return [.command(c),.clearSelection]}
        case .polygonSides:
            guard n.rounded() == n,(3...1024).contains(n) else {throw CoreError.message("Polygon needs 3–1024 sides")};defaults.sides = Int(n);stage = .points
        case .radius:
            guard n>0 else {throw CoreError.message("Radius/diameter must be positive")};defaults.radius = diameter ? n/2:n
            let c = "CIRCLE \(points[0].command) \(diameter ? n/2:n)";reset();return [.command(c)]
        case .distance:
            guard n>0 else {throw CoreError.message("Offset distance must be positive")};defaults.distance = n;stage = selected>0 ? .offsetSide:.selection
        case .filletRadius:
            guard n>=0 else {throw CoreError.message("Fillet radius cannot be negative")};defaults.fillet = n
            if selected>0 {let c = "FILLET \(n)";reset();return [.command(c),.clearSelection]};stage = .selection
        case .chamferFirst:
            guard n>0 else {throw CoreError.message("Chamfer distance must be positive")};defaults.chamferA = n;stage = .chamferSecond
        case .chamferSecond:
            guard n>0 else {throw CoreError.message("Chamfer distance must be positive")};defaults.chamferB = n
            if selected>0 {let c = "CHAMFER \(defaults.chamferA) \(n)";reset();return [.command(c),.clearSelection]};stage = .selection
        case .textHeight:
            guard n>0 else {throw CoreError.message("Text height must be positive")};defaults.height = n;stage = name == "MTEXT" ? .textValue:.textRotation
        case .textRotation: defaults.rotation = n;stage = .textValue
        case .angle,.factor:
            guard stage != .factor || n>0 else {throw CoreError.message("Scale must be positive")}
            let c = "\(tool == .rotate ? "ROTATE":"SCALE") \(points[0].command) \(n)";reset();return [.command(c),.clearSelection]
        case .points:
            if tool == .line || tool == .polyline,let base = points.last,let cursor {
                let d = cursor-base;let length = d.distance(.zero)
                guard n>0,length>1e-9 else {throw CoreError.message("Point in the desired direction, or enter @distance<angle")}
                return try point(base+d*(n/length),selected:selected)
            }
            if tool == .polygon,let center = points.first {
                guard n>0 else {throw CoreError.message("Radius must be positive")}
                let radius = circumscribed ? n/cos(.pi/Double(defaults.sides)):n
                let c = "POLYGON \(defaults.sides) \(center.command) \(radius) \(circumscribed ? 180/Double(defaults.sides):0)";reset();return [.command(c)]
            }
            if tool == .ellipse,points.count == 2 {
                let center = centerMode ? points[0]:(points[0]+points[1])*0.5
                let major = points[1].distance(center)
                guard n>0,n<=major else {throw CoreError.message("Minor radius must be positive and no greater than the major radius")}
                let c = "ELLIPSE \(center.command) \(points[1].command) \(n/major)";reset();return [.command(c)]
            }
            throw CoreError.message("This prompt needs a coordinate")
        default: throw CoreError.message("This prompt needs a coordinate or option")
        }
        return []
    }
    mutating func point(_ p:CADPoint,selected:Int) throws -> [Effect] {
        guard tool != .pan else{throw CoreError.message("Drag to pan; press Return/Space to finish")}
        guard p.x.isFinite,p.y.isFinite,abs(p.x)<=1e12,abs(p.y)<=1e12 else {throw CoreError.message("Invalid coordinate")}
        if stage == .offsetSide {return [.command("OFFSET \(defaults.distance) \(p.command)")]}
        if stage == .radius {return try scalar(points[0].distance(p)*(diameter ? 2:1),selected:selected)}
        if stage == .angle {let d = p-points[0];return try scalar(atan2(d.y,d.x)*180 / .pi,selected:selected)}
        guard stage == .points else {throw CoreError.message("Complete the displayed value or selection prompt first")}
        if tool == .ellipse, points.count == 2 {
            let center = centerMode ? points[0]:(points[0]+points[1])*0.5;let axis = points[1]-center;let d = p-center
            return try scalar(abs(axis.x*d.y-axis.y*d.x)/max(axis.distance(.zero),1e-9),selected:selected)
        }
        if tool == .polygon,!points.isEmpty {
            let center = points[0];let n = center.distance(p);guard n>0 else{throw CoreError.message("Radius must be positive")}
            let radius = circumscribed ? n/cos(.pi/Double(defaults.sides)):n
            let rotation = atan2(p.y-center.y,p.x-center.x)*180 / .pi + (circumscribed ? 180/Double(defaults.sides):0)
            let c = "POLYGON \(defaults.sides) \(center.command) \(radius) \(rotation)";reset();return [.command(c)]
        }
        if let last = points.last,last.distance(p)<1e-9,[.line,.polyline,.spline,.arc,.ellipse,.mirror].contains(tool) {throw CoreError.message("Specify a distinct point")}
        points.append(p)
        if name == "ZOOM",points.count == 2 {
            let a = points[0];guard a.x != p.x,a.y != p.y else{throw CoreError.message("Zoom window needs width and height")}
            reset();return [.zoomWindow(CADBounds(min:.init(x:min(a.x,p.x),y:min(a.y,p.y)),max:.init(x:max(a.x,p.x),y:max(a.y,p.y))))]
        }
        var command:String?
        switch tool {
        case .breakLine:command = "BREAK \(p.command)"
        case .block:command = "BLOCK \(text) \(p.command)"
        case .insert:stage = .insertScale
        case .arrayPolar:stage = .values
        case .line where points.count>1: return [.command("LINE \(points[points.count-2].command) \(p.command)")]
        case .rectangle where points.count == 2, .hatch where points.count == 2:
            let a = points[0]
            command = tool == .rectangle ? "RECT \(a.command) \(p.command)":"HATCH diagonal \(max(a.distance(p)/30,0.01)) \(a.command) \(CADPoint(x:p.x,y:a.y).command) \(p.command) \(CADPoint(x:a.x,y:p.y).command)"
        case .circle:
            if circlePoints == 0 {stage = .radius}
            else if points.count == circlePoints {command = "CIRCLE\(circlePoints) "+points.map(\.command).joined(separator:" ")}
        case .point: command = "POINT \(p.command)"
        case .arc where points.count == 3:
            if centerMode {let a = points[1]-points[0],b = p-points[0];let start = atan2(a.y,a.x)*180 / .pi;let sweep = (atan2(b.y,b.x)*180 / .pi-start+360).truncatingRemainder(dividingBy:360);command = "ARC \(points[0].command) \(a.distance(.zero)) \(start) \(sweep)"}
            else {command = "ARC3 "+points.map(\.command).joined(separator:" ")}
        case .polygon: stage = .polygonMode
        case .text: stage = .textHeight
        case .rotate: stage = .angle
        case .scale: stage = .factor
        case .mirror where points.count == 2: stage = .mirrorDelete
        case .dimension where points.count == 3, .alignedDimension where points.count == 3:
            let a = points[0],b = points[1],d = b-a
            let offset = tool == .alignedDimension ? ((p.x-a.x)*(-d.y)+(p.y-a.y)*d.x)/max(d.distance(.zero),1e-9):(p.y-a.y)*(b.x>=a.x ? 1:-1)
            command = "\(tool == .alignedDimension ? "DIMALIGNED":"DIM") \(a.command) \(b.command) \(offset)"
        case .radius where points.count == 3, .diameter where points.count == 3: command = "\(tool == .diameter ? "DIMDIAMETER":"DIMRADIUS") "+points.map(\.command).joined(separator:" ")
        case .leader where points.count == 2: stage = .textValue
        case .trim where points.count == 3, .extend where points.count == 3: command = name+" "+points.map(\.command).joined(separator:" ")
        case .measure where points.count == 2: let a = points[0];reset();return [.measure(a,p)]
        case .move where points.count == 2, .copy where points.count == 2:
            let c = name+" "+(p-points[0]).command
            if tool == .copy {points.removeLast();return [.command(c)]}
            reset();return [.command(c),.clearSelection]
        default: break
        }
        if let command {reset();return [.command(command)]}
        return []
    }
    static func coordinate(_ raw:String,base:CADPoint?) -> CADPoint? {
        var input = raw.trimmingCharacters(in:.whitespaces)
        let relative = input.hasPrefix("@")
        if relative || input.hasPrefix("#") {input.removeFirst()}
        let origin = relative ? (base ?? .zero):.zero
        let pair = input.split(separator:",",omittingEmptySubsequences:false)
        if pair.count == 2,let x = Double(pair[0]),let y = Double(pair[1]),x.isFinite,y.isFinite {return origin+CADPoint(x:x,y:y)}
        let polar = input.split(separator:"<",omittingEmptySubsequences:false)
        if polar.count == 2,let d = Double(polar[0]),let a = Double(polar[1]),d.isFinite,a.isFinite {return origin+CADPoint(x:cos(a * .pi/180),y:sin(a * .pi/180))*d}
        return nil
    }
}

extension Tool {
    var requiresSelection:Bool {[.erase,.join,.explode,.breakLine,.block,.arrayRect,.arrayPolar,.move,.copy,.rotate,.scale,.mirror,.offset,.trim,.extend,.fillet,.chamfer].contains(self)}
    var commandName:String {
        switch self {
        case .breakLine:return "BREAK"
        case .arrayRect:return "ARRAYRECT"
        case .arrayPolar:return "ARRAYPOLAR"
        case .polyline:return "PLINE"
        case .rectangle:return "RECTANG"
        case .alignedDimension:return "DIMALIGNED"
        case .dimension:return "DIMLINEAR"
        case .radius:return "DIMRADIUS"
        case .diameter:return "DIMDIAMETER"
        case .measure:return "DIST"
        default:return rawValue.uppercased()
        }
    }
    static let aliases:[String:Tool] = ["J":.join,"JOIN":.join,"X":.explode,"EXPLODE":.explode,"BR":.breakLine,"BREAK":.breakLine,"AR":.arrayRect,"ARRAY":.arrayRect,"ARRAYRECT":.arrayRect,"ARRAYPOLAR":.arrayPolar,"B":.block,"BLOCK":.block,"I":.insert,"INSERT":.insert,"P":.pan,"PAN":.pan,"L":.line,"LINE":.line,"PL":.polyline,"PLINE":.polyline,"POLYLINE":.polyline,"REC":.rectangle,"RECT":.rectangle,"RECTANG":.rectangle,"RECTANGLE":.rectangle,"C":.circle,"CIRCLE":.circle,"A":.arc,"ARC":.arc,"EL":.ellipse,"ELLIPSE":.ellipse,"SPL":.spline,"SPLINE":.spline,"POL":.polygon,"POLYGON":.polygon,"PO":.point,"POINT":.point,"T":.text,"TEXT":.text,"MT":.text,"MTEXT":.text,"DIM":.dimension,"DIMLINEAR":.dimension,"DLI":.dimension,"DIMALIGNED":.alignedDimension,"DAL":.alignedDimension,"DIMRADIUS":.radius,"DRA":.radius,"DIMDIAMETER":.diameter,"DDI":.diameter,"LE":.leader,"LEADER":.leader,"MLEADER":.leader,"H":.hatch,"HATCH":.hatch,"M":.move,"MOVE":.move,"CO":.copy,"CP":.copy,"COPY":.copy,"RO":.rotate,"ROTATE":.rotate,"SC":.scale,"SCALE":.scale,"MI":.mirror,"MIRROR":.mirror,"O":.offset,"OFFSET":.offset,"TR":.trim,"TRIM":.trim,"EX":.extend,"EXTEND":.extend,"F":.fillet,"FILLET":.fillet,"CHA":.chamfer,"CHAMFER":.chamfer,"DI":.measure,"DIST":.measure,"E":.erase,"ERASE":.erase,"DELETE":.erase]
    static func normalized(_ input:String)->String {String(input.drop(while:{$0 == "_" || $0 == "."})).uppercased()}
}
