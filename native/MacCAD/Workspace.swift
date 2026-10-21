import SwiftUI
import AppKit

struct WorkspaceView: View {
    @ObservedObject var model: EditorModel
    var body: some View {
        VStack(spacing:0) {
            HStack(spacing:14) {
                icon("New","doc.badge.plus"){NSDocumentController.shared.newDocument(nil)}
                icon("Open","folder"){NSDocumentController.shared.openDocument(nil)}
                icon("Save","square.and.arrow.down"){model.document?.save(nil)}
                Divider().frame(height:22)
                icon("Undo","arrow.uturn.backward"){model.execute("UNDO")}.disabled(!model.canUndo)
                icon("Redo","arrow.uturn.forward"){model.execute("REDO")}.disabled(!model.canRedo)
                Divider().frame(height:22)
                icon("Export DXF","square.and.arrow.up"){model.document?.exportDXF(nil)}
                icon("Plot / PDF","printer"){model.document?.exportPDF(nil)}
                Divider().frame(height:22)
                Button{model.choose(.select)}label:{Label("Select",systemImage:"cursorarrow")}
                Menu("Selection") {
                    Button("Select All"){model.operation(["op":"select_all"])}
                    Button("Clear Selection"){model.operation(["op":"select","ids":[]])}
                    Button("Select Similar"){model.execute("SELECTSIMILAR")}
                    Button("Measure Selection"){model.measureSelection()}
                }.fixedSize()
                Spacer()
                icon("Zoom extents","arrow.up.left.and.arrow.down.right"){model.fitView?()}
                icon("Command history","terminal"){model.showCommandHistory.toggle()}
                icon("Properties","sidebar.right"){model.showProperties.toggle()}
                icon("Command reference","questionmark.circle"){model.showCommandReference = true}
            }.buttonStyle(.borderless).padding(.horizontal,16).padding(.vertical,10)
            Divider()
            HSplitView {
                toolSets.frame(minWidth:162,idealWidth:178,maxWidth:220)
                VStack(spacing:0) {
                    HStack{Image(systemName:"doc.text").foregroundStyle(.secondary);Text(model.drawingTitle).font(.system(size:11,weight:.medium)).lineLimit(1);Spacer();Text("MODEL SPACE").font(.system(size:9,weight:.medium)).tracking(1).foregroundStyle(.secondary)}.padding(.horizontal,12).padding(.vertical,7).background(.bar)
                    ZStack(alignment:.topLeading) {
                        CanvasHost(model:model)
                        Text("[Top]  [2D Wireframe]").font(.system(size:11)).foregroundStyle(.white.opacity(0.65)).padding(12).allowsHitTesting(false)
                    }.frame(minWidth:450,minHeight:350)
                    commandArea
                }
                if model.showProperties {InspectorView(model:model).frame(minWidth:245,idealWidth:280,maxWidth:360)}
            }
            Divider()
            HStack(spacing:12) {
                Text("Model").font(.system(size:10,weight:.semibold)).padding(.horizontal,12).padding(.vertical,4).background(Color.accentColor.opacity(0.12),in:RoundedRectangle(cornerRadius:3))
                Text(model.message).lineLimit(1).truncationMode(.middle);Spacer(minLength:4)
                Text(String(format:"%.2f, %.2f",model.coordinate.x,model.coordinate.y)).monospacedDigit().frame(minWidth:120,alignment:.trailing);Text(model.units).foregroundStyle(.tertiary)
                toggle("Grid",$model.grid);toggle("Snap",$model.snapping);toggle("Ortho",$model.ortho);toggle("Polar",$model.polar);toggle("LWT",$model.lineWeights)
            }.font(.system(size:10)).foregroundStyle(.secondary).padding(.horizontal,10).padding(.vertical,5)
        }.background(Color(nsColor:.windowBackgroundColor))
        .onChange(of:model.grid){model.invalidate?()}.onChange(of:model.lineWeights){model.invalidate?()}
        .task{await model.refresh()}
        .alert("Drawing command",isPresented:Binding(get:{model.errorMessage != nil},set:{if !$0{model.errorMessage = nil}})){Button("OK"){model.errorMessage = nil}}message:{Text(model.errorMessage ?? "")}
        .sheet(isPresented:$model.showCommandReference){CommandReference(model:model)}
    }
    private var toolSets:some View {
        ScrollView{VStack(alignment:.leading,spacing:16){
            Text("TOOL SETS").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
            toolGroup("Draw",[.line,.polyline,.rectangle,.polygon,.circle,.arc,.ellipse,.spline,.point])
            toolGroup("Modify",[.move,.copy,.rotate,.scale,.mirror,.offset,.trim,.extend,.fillet,.chamfer])
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:4){
                action("Join","point.3.connected.trianglepath.dotted"){model.execute("JOIN")}
                action("Break","scissors"){model.promptCommand("BREAK","Point on the selected line (x,y)","0,0")}
                action("Array","square.grid.3x3"){model.promptCommand("ARRAYRECT","Rows columns X-spacing Y-spacing","2 3 1000 1000")}
                action("Polar Array","circle.grid.3x3"){model.promptCommand("ARRAYPOLAR","Center-x,y count total-angle","0,0 6 360")}
                action("Explode","square.stack.3d.up.slash"){model.execute("EXPLODE")}
                action("Erase","trash"){model.execute("ERASE")}
            }
            toolGroup("Annotate",[.text,.dimension,.radius,.leader,.hatch,.measure])
            VStack(alignment:.leading,spacing:7){Text("BLOCKS").font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
                Button("Create from selection…"){model.promptCommand("BLOCK","Name and base point","Block1 0,0")}
                Menu("Insert Block"){ForEach(model.blocks,id:\.self){name in Button(name){model.promptCommand("INSERT","Name, insertion point, scale and angle","\(name) 0,0 1 0")}}}.disabled(model.blocks.isEmpty)
            }.font(.system(size:11))
            if model.entityCount == 0 {Button("Open example plan"){model.demo()}.font(.caption).buttonStyle(.link)}
        }.padding(12)}
    }
    private func toolGroup(_ title:String,_ tools:[Tool])->some View {
        VStack(alignment:.leading,spacing:7){Text(title.uppercased()).font(.system(size:10,weight:.semibold)).foregroundStyle(.secondary)
            LazyVGrid(columns:[GridItem(.flexible()),GridItem(.flexible())],spacing:4){ForEach(tools){tool in
                Button{model.choose(tool)}label:{VStack(spacing:5){Image(systemName:tool.symbol).font(.system(size:15)).frame(height:18);Text(tool.title).font(.system(size:9)).lineLimit(1)}.frame(maxWidth:.infinity).padding(.vertical,8)}.buttonStyle(.plain).background(model.tool == tool ? Color.accentColor.opacity(0.16):Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:5)).help(tool.prompt).accessibilityLabel(tool.title)
            }}
        }
    }
    private func action(_ title:String,_ symbol:String,_ action:@escaping()->Void)->some View{Button(action:action){VStack(spacing:5){Image(systemName:symbol).font(.system(size:14)).frame(height:18);Text(title).font(.system(size:9))}.frame(maxWidth:.infinity).padding(.vertical,8)}.buttonStyle(.plain).background(Color.primary.opacity(0.025),in:RoundedRectangle(cornerRadius:5)).accessibilityLabel(title)}
    private var commandArea:some View {
        VStack(alignment:.leading,spacing:0){Divider()
            if model.showCommandHistory {
                ScrollViewReader{proxy in ScrollView{VStack(alignment:.leading,spacing:3){ForEach(Array(model.commandHistory.enumerated()),id:\.offset){i,text in Text(text).font(.system(size:10,design:.monospaced)).foregroundStyle(.secondary).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading).id(i)}}.padding(.horizontal,12).padding(.vertical,6)}.frame(height:68).onChange(of:model.commandHistory.count){proxy.scrollTo(model.commandHistory.count-1,anchor:.bottom)}}
            }
            HStack(spacing:8){Text("Command:").font(.system(size:11,weight:.medium));CommandInput(model:model).frame(height:24);Text(model.tool.title).font(.caption).foregroundStyle(.secondary)}.padding(.horizontal,12).padding(.vertical,5)
            Text(model.tool == .select ? "Window: left → right  ·  Crossing: right → left  ·  Shift to add":model.message).font(.system(size:9)).foregroundStyle(.tertiary).padding(.horizontal,12).padding(.bottom,5)
        }.background(.bar)
    }
    private func toggle(_ title:String,_ value:Binding<Bool>)->some View{Button{value.wrappedValue.toggle()}label:{Text(title.uppercased()).font(.system(size:9,weight:.medium)).foregroundStyle(value.wrappedValue ? Color.accentColor:.secondary)}.buttonStyle(.plain)}
    private func icon(_ title:String,_ symbol:String,_ action:@escaping()->Void)->some View{Button(action:action){Image(systemName:symbol).frame(width:18)}.help(title).accessibilityLabel(title)}
}

struct CommandReference:View {
    @ObservedObject var model:EditorModel
    var body:some View{VStack(alignment:.leading,spacing:14){Text("2D command reference").font(.title2.weight(.semibold));Text("Coordinates use drawing units. Select objects before modifying. Angles are degrees. Up/Down recalls history; Tab completes commands.").foregroundStyle(.secondary)
        ScrollView{Text("""
        LINE 0,0 3000,0          RECT 0,0 8000,6000
        PLINE 0,0 1000,0:0.414214 1000,1000 close
        CIRCLE 4000,3000 600     ARC 0,0 1000 0 90
        ARC3 0,0 500,500 1000,0
        ELLIPSE 0,0 2000,0 0.5
        SPLINE 0,0 1000,2000 2000,2000 3000,0
        POLYGON 6 0,0 1000      POINT 0,0
        TEXT 1000,1000 150 Living room
        MTEXT 0,0 150 First line\\PSecond line
        DIM 0,0 8000,0 -500     DIMALIGNED 0,0 1000,1000 200
        DIMRADIUS 0,0 1000,0 1400,400
        LEADER 0,0 500,500 150 Note
        HATCH diagonal 100 0,0 2000,0 2000,1000 0,1000

        MOVE 500,0              COPY 1000,0
        ROTATE 0,0 90           SCALE 0,0 2
        MIRROR 0,0 0,1000       OFFSET 200
        TRIM 0,0 0,1000 -100,0
        EXTEND 0,0 0,1000 -100,0
        FILLET 200              CHAMFER 100 200
        ARRAYRECT 2 3 1000 1000
        ARRAYPOLAR 0,0 6 360
        JOIN / BREAK 500,0 / REVERSE / CLOSE / OPEN
        STRETCH 0,0 1000,1000 100,0
        BLOCK door 0,0          INSERT door 2000,0 1 90
        EXPLODE / ERASE / UNDO / REDO
        CHPROP layer Walls     CHPROP color #FF8800
        CHPROP linetype Dashed  CHPROP lineweight 0.5
        MATCHPROP 1            SELECTSIMILAR
        LAYISO / LAYUNISO / LAYON / LAYOFF / LAYLOCK / LAYUNLOCK
        OVERKILL / PURGE        AREA / LIST
        UNITS mm               ZOOM EXTENTS
        """).font(.system(size:11,design:.monospaced)).textSelection(.enabled).frame(maxWidth:.infinity,alignment:.leading)}
        Button("Done"){model.showCommandReference = false}.keyboardShortcut(.defaultAction).frame(maxWidth:.infinity,alignment:.trailing)
    }.padding(24).frame(width:670,height:700)}
}

struct CommandInput:NSViewRepresentable {
    @ObservedObject var model:EditorModel
    func makeCoordinator()->Coordinator{Coordinator(model)}
    func makeNSView(context:Context)->NSTextField{let field = NSTextField();field.isBordered = false;field.drawsBackground = false;field.font = .monospacedSystemFont(ofSize:12,weight:.regular);field.placeholderString = "Type a command or coordinates";field.delegate = context.coordinator;field.setAccessibilityLabel("CAD command input");model.focusCommand = {[weak field] in field?.window?.makeFirstResponder(field)};return field}
    func updateNSView(_ field:NSTextField,context:Context){if field.stringValue != model.commandText{field.stringValue = model.commandText}}
    final class Coordinator:NSObject,NSTextFieldDelegate {
        let model:EditorModel;var index:Int?
        init(_ model:EditorModel){self.model = model}
        func controlTextDidChange(_ obj:Notification){guard let field = obj.object as? NSTextField else{return};model.commandText = field.stringValue;index = nil}
        func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool{
            if selector == #selector(NSResponder.insertNewline(_:)){model.submit();textView.string = "";index = nil;return true}
            if selector == #selector(NSResponder.cancelOperation(_:)){model.cancel();model.commandText = "";textView.string = "";return true}
            if selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:)){let history = model.commandHistory;guard !history.isEmpty else{return true};let delta = selector == #selector(NSResponder.moveUp(_:)) ? -1:1;index = min(max((index ?? history.count)+delta,0),history.count);let value = index!<history.count ? history[index!]:"";model.commandText = value;textView.string = value;textView.setSelectedRange(NSRange(location:(value as NSString).length,length:0));return true}
            if selector == #selector(NSResponder.insertTab(_:)){let prefix = model.commandText.uppercased();if let name = Tool.allCases.map({$0.rawValue.uppercased()}).first(where:{$0.hasPrefix(prefix)}){model.commandText = name;textView.string = name;textView.setSelectedRange(NSRange(location:name.count,length:0))};return true}
            return false
        }
    }
}
