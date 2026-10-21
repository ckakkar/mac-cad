import SwiftUI
import AppKit

struct WorkspaceView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:3) {
                ForEach(Tool.allCases) { tool in
                    Button { model.choose(tool) } label: { Image(systemName:tool.symbol).frame(width:28,height:27) }
                        .buttonStyle(.borderless)
                        .background(model.tool == tool ? Color.accentColor.opacity(0.18) : .clear, in:RoundedRectangle(cornerRadius:5))
                        .help(tool.title).accessibilityLabel(tool.title)
                }
                Divider().frame(height:20).padding(.horizontal,8)
                Button { model.execute("UNDO") } label: { Image(systemName:"arrow.uturn.backward") }.disabled(!model.canUndo).help("Undo")
                Button { model.execute("REDO") } label: { Image(systemName:"arrow.uturn.forward") }.disabled(!model.canRedo).help("Redo")
                Spacer()
                Button { model.fitView?() } label: { Image(systemName:"arrow.up.left.and.arrow.down.right") }.help("Zoom to drawing")
                Button { model.showCommandReference.toggle() } label: { Image(systemName:"terminal") }.help("Command reference")
            }
            .buttonStyle(.borderless).padding(.horizontal,14).padding(.vertical,9)
            Divider()
            HSplitView {
                VStack(alignment:.leading,spacing:0) {
                    HStack { Text("LAYERS").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary); Spacer(); Text("\(model.layers.count)").font(.caption).foregroundStyle(.tertiary) }.padding(14)
                    ScrollView {
                        VStack(spacing:3) {
                            ForEach(model.layers) { layer in
                                HStack(spacing:7) {
                                    RoundedRectangle(cornerRadius:2).fill(Color(red:Double(layer.color[0]),green:Double(layer.color[1]),blue:Double(layer.color[2]))).frame(width:9,height:9)
                                    Button(layer.name) { model.layer(layer.name,values:["current":true]) }.buttonStyle(.plain).lineLimit(1)
                                    Spacer()
                                    Button { model.layer(layer.name,values:["visible":!layer.visible]) } label: { Image(systemName:layer.visible ? "eye" : "eye.slash") }.help("Toggle visibility")
                                    Button { model.layer(layer.name,values:["locked":!layer.locked]) } label: { Image(systemName:layer.locked ? "lock.fill" : "lock.open") }.help("Toggle lock")
                                }
                                .font(.system(size:11)).buttonStyle(.borderless).padding(.horizontal,10).padding(.vertical,8)
                                .background(model.currentLayer == layer.name ? Color.accentColor.opacity(0.10) : .clear,in:RoundedRectangle(cornerRadius:5))
                            }
                        }.padding(.horizontal,6)
                    }
                    HStack { TextField("New layer",text:$model.newLayerName).onSubmit(addLayer); Button(action:addLayer) { Image(systemName:"plus") }.disabled(model.newLayerName.isEmpty) }.padding(10)
                    Divider()
                    VStack(alignment:.leading,spacing:12) {
                        Text("PROPERTIES").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
                        Text(model.selectionDescription).font(.system(size:11)).foregroundStyle(.secondary).textSelection(.enabled)
                        Picker("Units",selection:Binding(get:{model.units},set:{model.execute("UNITS \($0)")})) {
                            ForEach(["mm","cm","m","in","ft"],id:\.self) { Text($0).tag($0) }
                        }.font(.caption)
                        Text("\(model.entityCount.formatted()) objects").font(.caption).foregroundStyle(.secondary)
                    }.padding(14)
                    if model.entityCount == 0 {
                        Button("Open example plan") { model.demo() }.buttonStyle(.link).font(.caption).padding(14)
                    }
                    Spacer(minLength:12)
                    HStack { Image(systemName:"cpu"); Text("APPLE SILICON").tracking(1) }.font(.system(size:9,weight:.medium)).foregroundStyle(.tertiary).padding(14)
                }.frame(minWidth:190,idealWidth:210,maxWidth:300)
                ZStack(alignment:.topLeading) {
                    CanvasHost(model:model)
                    HStack(spacing:7) { Circle().fill(.mint).frame(width:5,height:5); Text("MODEL SPACE").tracking(1.5); Text("/ 2D").foregroundStyle(.tertiary) }
                        .font(.system(size:9,weight:.medium)).foregroundStyle(.secondary).padding(.horizontal,12).padding(.vertical,8)
                        .background(.ultraThinMaterial,in:RoundedRectangle(cornerRadius:5)).padding(14).allowsHitTesting(false)
                }.frame(minWidth:480,minHeight:380)
            }
            Divider()
            HStack(spacing:10) {
                Image(systemName:"chevron.right").font(.system(size:10,weight:.bold)).foregroundStyle(Color.accentColor)
                TextField("Command — e.g. LINE 0,0 3000,0",text:$model.commandText).textFieldStyle(.plain).font(.system(size:12,design:.monospaced)).onSubmit { model.submit() }
                Text(model.tool.title).font(.caption).foregroundStyle(.secondary)
            }.padding(.horizontal,16).padding(.vertical,12)
            Divider()
            HStack(spacing:14) {
                Text(model.message).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(String(format:"X %.2f   Y %.2f",model.coordinate.x,model.coordinate.y)).monospacedDigit().frame(minWidth:155,alignment:.trailing)
                Text(model.units).foregroundStyle(.tertiary)
                toggle("Grid",$model.grid); toggle("Snap",$model.snapping); toggle("Ortho",$model.ortho); toggle("Polar",$model.polar)
            }.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,14).padding(.vertical,7)
        }
        .background(Color(nsColor:.windowBackgroundColor))
        .onChange(of:model.grid) { model.invalidate?() }
        .task { await model.refresh() }
        .alert("Drawing command",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0 {model.errorMessage = nil}})) { Button("OK") { model.errorMessage = nil } } message: { Text(model.errorMessage ?? "") }
        .sheet(isPresented:$model.showCommandReference) { commandReference }
    }
    private func addLayer() { let name = model.newLayerName.trimmingCharacters(in:.whitespacesAndNewlines); guard !name.isEmpty else {return}; model.layer(name,values:["create":true]); model.newLayerName = "" }
    private func toggle(_ title: String,_ binding: Binding<Bool>) -> some View {
        Button { binding.wrappedValue.toggle() } label: { Text(title.uppercased()).font(.system(size:9,weight:.medium)).foregroundStyle(binding.wrappedValue ? Color.accentColor : .secondary) }.buttonStyle(.plain)
    }
    private var commandReference: some View {
        VStack(alignment:.leading,spacing:14) {
            Text("Precise by command").font(.title2.weight(.semibold))
            Text("Coordinates use drawing units. Select objects before edit commands. Angles are in degrees.").foregroundStyle(.secondary)
            ScrollView {
                Text("""
                LINE 0,0 3000,0
                RECT 0,0 8000,6000
                PLINE 0,0 1000,0:0.414214 1000,1000 close
                CIRCLE 4000,3000 600
                ARC 0,0 1000 0 90
                TEXT 1000,1000 150 Living room
                DIM 0,0 8000,0 -500
                DIMALIGNED 0,0 1000,1000 200
                HATCH diagonal 100 0,0 2000,0 2000,1000 0,1000

                MOVE 500,0                 displacement
                COPY 1000,0                displacement
                ROTATE 0,0 90              base, degrees
                SCALE 0,0 2                base, factor
                MIRROR 0,0 0,1000          axis; creates copy
                OFFSET 200                 lines/circles
                TRIM 0,0 0,1000 -100,0     boundary, discarded side
                EXTEND 0,0 0,1000 -100,0   boundary, side point
                BLOCK door 0,0             name, base
                INSERT door 2000,0 1 90    name, point, scale, degrees
                EXPLODE                    static blocks
                ERASE / UNDO / REDO
                UNITS mm                   cm, m, in, ft
                ZOOM EXTENTS
                """).font(.system(size:12,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)
            }
            HStack { Text("Trackpad: two-finger pan, pinch to zoom. Mouse: wheel zoom; Option-drag pan.").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Done") {model.showCommandReference = false}.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width:690,height:650)
    }
}
