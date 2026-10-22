import SwiftUI
import AppKit

struct InspectorView:View {
    @ObservedObject var model:EditorModel
    private let types = ["Continuous","Dashed","Hidden","Center","Dotted"]
    var body:some View{
        VStack(alignment:.leading,spacing:0){
            if model.showLayers {
            HStack{Text("Layers").font(.system(size:12,weight:.semibold));Spacer();Text("\(model.layers.count)").font(.caption).foregroundStyle(.secondary)}.padding(12)
            HStack(spacing:12){layerAction("Isolate","square.stack.3d.up","LAYISO");layerAction("Show all","eye","LAYUNISO");layerAction("Lock","lock","LAYLOCK");layerAction("Unlock all","lock.open","LAYUNLOCK")}.padding(.horizontal,12).padding(.bottom,8)
            Picker("Current",selection:Binding(get:{model.currentLayer},set:{model.layer($0,values:["current":true])})){ForEach(model.layers){l in Text(l.name).tag(l.name)}}.font(.system(size:11)).padding(.horizontal,10)
            TextField("Search layers",text:$model.layerSearch).textFieldStyle(.roundedBorder).font(.system(size:11)).padding(10)
            ScrollView{LazyVStack(spacing:1){ForEach(model.layers.filter{model.layerSearch.isEmpty || $0.name.localizedCaseInsensitiveContains(model.layerSearch)}){l in
                HStack(spacing:7){LayerColorWell(value:l.color,label:"Color of \(l.name)"){model.layer(l.name,values:["color":$0])}.frame(width:18,height:16)
                    Button(l.name){model.layer(l.name,values:["current":true])}.buttonStyle(.plain).lineLimit(1);Spacer(minLength:2)
                    Button{model.layer(l.name,values:["visible":!l.visible])}label:{Image(systemName:l.visible ? "eye":"eye.slash")}.help("Visibility: \(l.name)")
                    Button{model.layer(l.name,values:["locked":!l.locked])}label:{Image(systemName:l.locked ? "lock.fill":"lock.open")}.help("Lock: \(l.name)")
                }.font(.system(size:10)).buttonStyle(.borderless).padding(.horizontal,8).padding(.vertical,7).background(model.currentLayer == l.name ? Color.accentColor.opacity(0.12):.clear)
            }}}.frame(minHeight:100,maxHeight:240)
            HStack{TextField("New layer",text:$model.newLayerName).onSubmit(addLayer);Button(action:addLayer){Image(systemName:"plus")}.disabled(model.newLayerName.isEmpty)}.padding(10).font(.system(size:11))
            if let l = model.layers.first(where:{$0.name == model.currentLayer}){
                HStack{Text("Linetype").foregroundStyle(.secondary);Spacer();Picker("Linetype",selection:Binding(get:{l.line_type},set:{model.layer(l.name,values:["line_type":$0])})){ForEach(types,id:\.self){Text($0)}}.labelsHidden()}.font(.system(size:10)).padding(.horizontal,12)
                HStack{Text("Weight").foregroundStyle(.secondary);Spacer();Picker("Weight",selection:Binding(get:{(Double(l.line_weight)*100).rounded()/100},set:{model.layer(l.name,values:["line_weight":$0])})){ForEach([0.0,0.09,0.13,0.18,0.25,0.35,0.5,0.7,1.0,2.11],id:\.self){Text(String(format:"%.2f mm",$0)).tag($0)}}.labelsHidden()}.font(.system(size:10)).padding(.horizontal,12).padding(.bottom,10)
            }
            }
            Divider()
            if model.showProperties {ScrollView{VStack(alignment:.leading,spacing:12){
                Text("Properties").font(.system(size:12,weight:.semibold))
                Text(model.selectionDescription).font(.system(size:10)).foregroundStyle(.secondary).textSelection(.enabled)
                if !model.selection.isEmpty {
                    Picker("Layer",selection:Binding(get:{entity["layer"] as? String ?? model.currentLayer},set:{model.patch(["layer":$0])})){ForEach(model.layers){Text($0.name).tag($0.name)}}
                    Picker("Linetype",selection:Binding(get:{style["line_type"] as? String ?? "ByLayer"},set:{v in setStyle("line_type",v == "ByLayer" ? NSNull():v)})){Text("ByLayer").tag("ByLayer");ForEach(types,id:\.self){Text($0)}}
                    HStack{Text("Color");Spacer();ColorPicker("Object color",selection:Binding(get:{color(effectiveColor)},set:{setStyle("color",components($0))}),supportsOpacity:false).labelsHidden();Button("ByLayer"){setStyle("color",NSNull())}.buttonStyle(.link)}
                    Picker("Weight",selection:Binding(get:{(style["line_weight"] as? NSNumber)?.doubleValue ?? -1},set:{v in setStyle("line_weight",v<0 ? NSNull():v)})){Text("ByLayer").tag(-1.0);ForEach([0.0,0.13,0.18,0.25,0.35,0.5,0.7,1.0],id:\.self){Text(String(format:"%.2f mm",$0)).tag($0)}}
                    if model.selection.count == 1 {Divider();ForEach(geometryKeys,id:\.self){key in HStack{Text(key.capitalized).foregroundStyle(.secondary);Spacer();TextField(key,text:Binding(get:{model.propertyDraft[key] ?? display(key)},set:{model.propertyDraft[key] = $0})).multilineTextAlignment(.trailing).frame(maxWidth:145).onSubmit{commit(key)}}}}
                    Button("Length / Area"){model.measureSelection()}.buttonStyle(.link)
                    if !model.measurement.isEmpty{Text(model.measurement).font(.system(size:10,design:.monospaced)).textSelection(.enabled)}
                }
                Divider()
                Picker("Units",selection:Binding(get:{model.units},set:{model.execute("UNITS \($0)")})){ForEach(["mm","cm","m","in","ft"],id:\.self){Text($0)}}
                Text("\(model.entityCount.formatted()) objects · \(model.selection.count) selected").foregroundStyle(.secondary)
            }.font(.system(size:11)).padding(12)}}
        }
    }
    private var entity:[String:Any]{model.selectionData.first ?? [:]}
    private var style:[String:Any]{entity["style"] as? [String:Any] ?? [:]}
    private var effectiveColor:[Float]{if let c = style["color"] as? [Float]{return c};let name = entity["layer"] as? String ?? model.currentLayer;return model.layers.first(where:{$0.name == name})?.color ?? [0.8,0.85,0.9,1]}
    private var geometryKeys:[String]{["a","b","at","center","major","radius","ratio","start","sweep","height","text","offset","scale","rotation"].filter{entity[$0] != nil}}
    private func setStyle(_ key:String,_ value:Any){var s = style;s[key] = value;model.patch(["style":s])}
    private func display(_ key:String)->String{
        if let p = entity[key] as? [String:Double],let x = p["x"],let y = p["y"]{return String(format:"%.4f,%.4f",x,y)}
        if let n = entity[key] as? NSNumber{return String(format:"%.5g",["start","sweep","rotation"].contains(key) ? n.doubleValue*180 / .pi:n.doubleValue)}
        return entity[key] as? String ?? ""
    }
    private func commit(_ key:String){
        let raw = model.propertyDraft[key] ?? display(key);var value:Any
        if entity[key] is [String:Any]{let parts = raw.split(separator:",");guard parts.count == 2,let x = Double(parts[0]),let y = Double(parts[1]) else{model.show(CoreError.message("Use x,y coordinates"));return};value = ["x":x,"y":y]}
        else if entity[key] is NSNumber{guard let n = Double(raw),n.isFinite else{model.show(CoreError.message("Enter a finite number"));return};value = ["start","sweep","rotation"].contains(key) ? n * .pi/180:n}
        else{value = raw}
        model.patch(["geometry":[key:value]])
    }
    private func addLayer(){let name = model.newLayerName.trimmingCharacters(in:.whitespacesAndNewlines);guard !name.isEmpty else{return};model.layer(name,values:["create":true]);model.newLayerName = ""}
    private func layerAction(_ title:String,_ symbol:String,_ command:String)->some View{Button{model.execute(command)}label:{Image(systemName:symbol)}.buttonStyle(.borderless).help(title)}
    private func color(_ c:[Float])->Color{Color(red:Double(c[0]),green:Double(c[1]),blue:Double(c[2]))}
    private func components(_ color:Color)->[Float]{let c = NSColor(color).usingColorSpace(.sRGB) ?? .white;return [Float(c.redComponent),Float(c.greenComponent),Float(c.blueComponent),1]}
}

struct LayerColorWell:NSViewRepresentable {
    let value:[Float]
    let label:String
    let changed:([Float])->Void
    func makeCoordinator()->Coordinator{Coordinator(changed)}
    func makeNSView(context:Context)->NSColorWell{let well = CompactColorWell(frame:NSRect(x:0,y:0,width:18,height:16));well.colorWellStyle = .minimal;well.controlSize = .mini;well.isBordered = false;well.target = context.coordinator;well.action = #selector(Coordinator.change(_:));well.setAccessibilityLabel(label);return well}
    func sizeThatFits(_ proposal:ProposedViewSize,nsView:NSColorWell,context:Context)->CGSize?{CGSize(width:18,height:16)}
    func updateNSView(_ well:NSColorWell,context:Context){well.color = NSColor(srgbRed:CGFloat(value[0]),green:CGFloat(value[1]),blue:CGFloat(value[2]),alpha:1);context.coordinator.changed = changed}
    final class Coordinator:NSObject{var changed:([Float])->Void;init(_ changed:@escaping([Float])->Void){self.changed = changed};@objc func change(_ sender:NSColorWell){let c = sender.color.usingColorSpace(.sRGB) ?? .white;changed([Float(c.redComponent),Float(c.greenComponent),Float(c.blueComponent),1])}}
}

/// NSColorWell's modern bezel has a large minimum drawing width. Keep its native
/// panel/accessibility behavior while painting a swatch within the layer row.
final class CompactColorWell:NSColorWell {
    override var intrinsicContentSize:NSSize{NSSize(width:18,height:16)}
    override func draw(_ dirtyRect:NSRect){color.setFill();NSBezierPath(roundedRect:bounds.insetBy(dx:1,dy:2),xRadius:3,yRadius:3).fill()}
}
