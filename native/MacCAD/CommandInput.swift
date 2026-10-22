import AppKit
import SwiftUI

/// A dedicated field editor confines CAD key semantics to command inputs. Text
/// labels, property fields and file dialogs retain standard macOS text editing.
@MainActor final class CADCommandField:NSTextField {
    weak var model:EditorModel?
    private var commandDelegate:CommandTextDelegate!
    init(model:EditorModel) {
        self.model = model;super.init(frame:.zero)
        commandDelegate = CommandTextDelegate(model);delegate = commandDelegate
        isBordered = false;drawsBackground = false;font = .monospacedSystemFont(ofSize:12,weight:.regular)
        placeholderString = "Type a command or coordinates";setAccessibilityLabel("CAD command input")
    }
    required init?(coder:NSCoder){fatalError("init(coder:) is not used")}
    func synchronize() {
        guard let model else{return}
        if stringValue != model.commandText {stringValue = model.commandText}
        if let editor = currentEditor() as? NSTextView,editor.string != model.commandText {editor.string = model.commandText;editor.setSelectedRange(NSRange(location:(model.commandText as NSString).length,length:0))}
    }
    func focus() {
        synchronize();window?.makeFirstResponder(self)
        (currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location:(stringValue as NSString).length,length:0))
    }
}
@MainActor final class CADFieldEditor:NSTextView {
    weak var commandModel:EditorModel?
    override func keyDown(with event:NSEvent) {
        if let model = commandModel {
            if model.handleCADKey(event) {return}
            if event.keyCode == 49,event.modifierFlags.intersection([.command,.control,.option]).isEmpty,!hasMarkedText(),model.spaceSubmits {
                model.submit();string = "";setSelectedRange(NSRange(location:0,length:0));return
            }
        }
        super.keyDown(with:event)
    }
}
@MainActor final class DrawingWindowController:NSWindowController,NSWindowDelegate {
    private lazy var commandEditor:CADFieldEditor = {let editor = CADFieldEditor();editor.isFieldEditor = true;return editor}()
    func windowWillReturnFieldEditor(_ sender:NSWindow,to client:Any?)->Any? {
        guard let field = client as? CADCommandField else{return nil}
        commandEditor.commandModel = field.model;return commandEditor
    }
}
@MainActor final class CommandTextDelegate:NSObject,NSTextFieldDelegate {
    weak var model:EditorModel?
    var index:Int?,draft = "",completionPrefix:String?,completionIndex = 0
    init(_ model:EditorModel){self.model = model}
    func controlTextDidChange(_ obj:Notification) {
        guard let field = obj.object as? NSTextField,let model else{return}
        model.commandText = field.stringValue;index = nil;completionPrefix = nil
    }
    func control(_ control:NSControl,textView:NSTextView,doCommandBy selector:Selector)->Bool {
        guard let model else{return false}
        if selector == #selector(NSResponder.insertNewline(_:)) {
            model.submit();textView.string = "";index = nil;completionPrefix = nil;return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            model.cancel();textView.string = "";index = nil;completionPrefix = nil;return true
        }
        if selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:)) {
            let history = model.inputHistory;guard !history.isEmpty else{return true}
            if index == nil {draft = model.commandText}
            let delta = selector == #selector(NSResponder.moveUp(_:)) ? -1:1
            index = min(max((index ?? history.count)+delta,0),history.count)
            let value = index!<history.count ? history[index!]:draft
            model.commandText = value;textView.string = value;textView.setSelectedRange(NSRange(location:(value as NSString).length,length:0));return true
        }
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            guard !model.session.acceptsSpaces,!model.commandText.contains(" ") else{return false}
            let prefix = completionPrefix ?? model.commandText.uppercased()
            let names = Set(Tool.aliases.values.map(\.commandName)+["ZOOM","PAN","JOIN","BREAK","EXPLODE","PURGE","OVERKILL","REVERSE","CLOSE","OPEN","SELECTSIMILAR","MATCHPROP","CHPROP","UNITS","UNDO","REDO","GRID","SNAP","OSNAP","ORTHO","POLAR","DYNMODE"]).filter{$0.hasPrefix(prefix)}.sorted()
            guard !names.isEmpty else{return true}
            if completionPrefix == nil {completionIndex = selector == #selector(NSResponder.insertBacktab(_:)) ? names.count-1:0}
            else {completionIndex = (completionIndex+(selector == #selector(NSResponder.insertBacktab(_:)) ? names.count-1:1))%names.count}
            completionPrefix = prefix;let name = names[completionIndex];model.commandText = name;textView.string = name;textView.setSelectedRange(NSRange(location:(name as NSString).length,length:0));return true
        }
        return false
    }
}
struct CommandInput:NSViewRepresentable {
    @ObservedObject var model:EditorModel
    func makeNSView(context:Context)->CADCommandField {
        let field = CADCommandField(model:model)
        model.focusCommandBar = {[weak field] in field?.focus()}
        model.syncCommandBar = {[weak field] in field?.synchronize()}
        return field
    }
    func updateNSView(_ field:CADCommandField,context:Context){field.synchronize()}
}
extension EditorModel {
    /// Function keys and CAD control shortcuts work on the canvas and in either
    /// command field. Ordinary text editors do not route through this method.
    func handleCADKey(_ event:NSEvent)->Bool {
        if event.modifierFlags.contains(.control) && !event.modifierFlags.contains(.command) {
            switch event.keyCode {
            case 38,46:submit();return true // Ctrl-J / Ctrl-M
            case 33,42:cancel();return true // Ctrl-[ / Ctrl-\
            case 3:snapping.toggle();invalidate?();return true
            case 37:ortho.toggle();if ortho{polar = false};invalidate?();return true
            case 6:execute("UNDO");return true
            case 16:execute("REDO");return true
            default:break
            }
        }
        switch event.keyCode {
        case 120:showCommandHistory.toggle();showCommandLine = true
        case 99:snapping.toggle()
        case 98:grid.toggle()
        case 100:ortho.toggle();if ortho{polar = false}
        case 101:gridSnap.toggle()
        case 109:polar.toggle();if polar{ortho = false}
        case 111:dynamicInput.toggle()
        default:return false
        }
        invalidate?();return true
    }
}
