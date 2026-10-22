import AppKit
import SwiftUI

/// A dedicated field editor confines CAD key semantics to command inputs. Text
/// labels, property fields and file dialogs retain standard macOS text editing.
@MainActor final class CADCommandField: NSTextField {
    weak var model: EditorModel?
    /// Called after Return/Space submits, e.g. to hand focus back to the canvas.
    var didSubmit: (() -> Void)?
    private var commandDelegate: CommandTextDelegate!
    init(model: EditorModel) {
        self.model = model; super.init(frame: .zero)
        commandDelegate = CommandTextDelegate(model); delegate = commandDelegate
        isBordered = false; drawsBackground = false; font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        focusRingType = .none
        placeholderString = "Type a command"; setAccessibilityLabel("Command input")
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
    func synchronize() {
        guard let model else { return }
        if stringValue != model.commandText { stringValue = model.commandText }
        let placeholder = model.session.active ? "" : "Type a command"
        if placeholderString != placeholder && drawsBackground == false { placeholderString = placeholder }
        if let editor = currentEditor() as? NSTextView, editor.string != model.commandText { editor.string = model.commandText; editor.setSelectedRange(NSRange(location: (model.commandText as NSString).length, length: 0)) }
    }
    func focus() {
        synchronize(); window?.makeFirstResponder(self)
        (currentEditor() as? NSTextView)?.setSelectedRange(NSRange(location: (stringValue as NSString).length, length: 0))
    }
}
@MainActor final class CADFieldEditor: NSTextView {
    weak var commandModel: EditorModel?
    override func keyDown(with event: NSEvent) {
        if let model = commandModel {
            if model.handleCADKey(event) { return }
            if event.keyCode == 49, event.modifierFlags.intersection([.command, .control, .option]).isEmpty, !hasMarkedText(), model.spaceSubmits {
                model.submitSuggestionOrText(); string = ""; setSelectedRange(NSRange(location: 0, length: 0))
                ((delegate as? NSObject) as? CADCommandField)?.didSubmit?(); return
            }
        }
        super.keyDown(with: event)
    }
}
@MainActor final class CommandTextDelegate: NSObject, NSTextFieldDelegate {
    weak var model: EditorModel?
    var index: Int?, draft = "", completionPrefix: String?, completionIndex = 0
    init(_ model: EditorModel) { self.model = model }
    func controlTextDidChange(_ obj: Notification) {
        guard let field = obj.object as? NSTextField, let model else { return }
        model.commandText = field.stringValue; model.suggestionIndex = nil; index = nil; completionPrefix = nil
    }
    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        guard let model else { return false }
        func set(_ value: String) { model.commandText = value; textView.string = value; textView.setSelectedRange(NSRange(location: (value as NSString).length, length: 0)) }
        if selector == #selector(NSResponder.insertNewline(_:)) {
            model.submitSuggestionOrText(); textView.string = ""; index = nil; completionPrefix = nil
            (control as? CADCommandField)?.didSubmit?(); return true
        }
        if selector == #selector(NSResponder.cancelOperation(_:)) {
            if model.suggestionIndex != nil { model.suggestionIndex = nil; return true }
            model.cancel(); textView.string = ""; index = nil; completionPrefix = nil; return true
        }
        if selector == #selector(NSResponder.moveUp(_:)) || selector == #selector(NSResponder.moveDown(_:)) {
            let up = selector == #selector(NSResponder.moveUp(_:))
            // Arrow keys walk the autocomplete list while it is showing, otherwise input history.
            let suggestions = model.suggestions
            if index == nil, !suggestions.isEmpty {
                let current = model.suggestionIndex ?? (up ? suggestions.count : -1)
                model.suggestionIndex = min(max(current + (up ? -1 : 1), 0), suggestions.count - 1); return true
            }
            let history = model.inputHistory; guard !history.isEmpty else { return true }
            if index == nil { draft = model.commandText }
            index = min(max((index ?? history.count) + (up ? -1 : 1), 0), history.count)
            set(index! < history.count ? history[index!] : draft); return true
        }
        if selector == #selector(NSResponder.insertTab(_:)) || selector == #selector(NSResponder.insertBacktab(_:)) {
            guard !model.session.acceptsSpaces, !model.commandText.contains(" ") else { return false }
            let prefix = completionPrefix ?? model.commandText.uppercased()
            let names = CommandCatalog.names.filter { $0.hasPrefix(prefix) }.sorted()
            guard !names.isEmpty else { return true }
            let back = selector == #selector(NSResponder.insertBacktab(_:))
            if completionPrefix == nil { completionIndex = back ? names.count - 1 : 0 }
            else { completionIndex = (completionIndex + (back ? names.count - 1 : 1)) % names.count }
            completionPrefix = prefix; set(names[completionIndex]); return true
        }
        return false
    }
}
struct CommandInput: NSViewRepresentable {
    let model: EditorModel
    func makeNSView(context: Context) -> CADCommandField {
        let field = CADCommandField(model: model)
        model.focusCommandBar = { [weak field] in field?.focus() }
        model.syncCommandBar = { [weak field] in field?.synchronize() }
        return field
    }
    func updateNSView(_ field: CADCommandField, context: Context) { field.synchronize() }
}

/// Command names with descriptions for completion and the suggestion list.
enum CommandCatalog {
    static let entries: [String: String] = {
        var out: [String: String] = [:]
        for tool in Tool.allCases where tool != .select { out[tool.commandName] = tool.title }
        out["MTEXT"] = "Multiline Text"
        let extras: [String: String] = [
            "ZOOM": "Zoom Extents, Window, Previous or factor", "PAN": "Pan the view", "UNDO": "Undo", "REDO": "Redo",
            "REVERSE": "Reverse line, arc or polyline direction", "CLOSE": "Close polylines", "OPEN": "Open polylines",
            "STRETCH": "Stretch vertices inside a window", "SELECTSIMILAR": "Select similar objects", "MATCHPROP": "Match properties",
            "CHPROP": "Change properties", "OVERKILL": "Delete duplicate objects", "PURGE": "Remove unused blocks and layers",
            "UNITS": "Drawing units", "GRID": "Grid display", "SNAP": "Snap mode", "OSNAP": "Object snap", "ORTHO": "Ortho mode",
            "POLAR": "Polar tracking", "DYNMODE": "Dynamic input", "DSETTINGS": "Drafting Settings", "LAYER": "Layers palette",
            "PROPERTIES": "Properties Inspector", "AREA": "Length and area of the selection", "LIST": "Length and area of the selection",
            "LAYISO": "Isolate selected objects' layers", "LAYUNISO": "Turn all layers on", "LAYON": "Turn all layers on",
            "LAYOFF": "Turn off selected objects' layers", "LAYLOCK": "Lock selected objects' layers", "LAYUNLOCK": "Unlock all layers",
            "LAYMCUR": "Make the object's layer current", "SELECT": "Select objects", "REGEN": "Regenerate", "OPTIONS": "Application settings",
            "ARRAY": "Rectangular array", "ARC3": "Three-point arc", "RECT": "Rectangle", "DIMLINEAR": "Linear dimension",
        ]
        out.merge(extras) { a, _ in a }
        return out
    }()
    static let names = Array(entries.keys)
    /// Alias target first (L → LINE), then prefix matches, shortest first.
    static func suggestions(for text: String) -> [String] {
        let typed = Tool.normalized(text.trimmingCharacters(in: .whitespaces))
        guard !typed.isEmpty, !typed.contains(" "), typed.first?.isLetter == true else { return [] }
        var out: [String] = []
        if let tool = Tool.aliases[typed] { out.append(tool.commandName) }
        for name in names.filter({ $0.hasPrefix(typed) }).sorted(by: { ($0.count, $0) < ($1.count, $1) }) where !out.contains(name) { out.append(name) }
        return Array(out.prefix(8))
    }
}

extension EditorModel {
    var suggestions: [String] { session.acceptsSpaces || session.active ? [] : CommandCatalog.suggestions(for: commandText) }
    /// Return/Space accept a highlighted suggestion, otherwise the typed text.
    func submitSuggestionOrText() {
        if let index = suggestionIndex, suggestions.indices.contains(index) { commandText = suggestions[index] }
        suggestionIndex = nil; submit()
    }
    /// Function keys and CAD control shortcuts work on the canvas and in either
    /// command field. Ordinary text editors do not route through this method.
    func handleCADKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection([.command, .control, .option, .shift])
        if flags == .control {
            switch event.keyCode {
            case 38, 46: submit(); return true // Ctrl-J / Ctrl-M
            case 33, 42: cancel(); return true // Ctrl-[ / Ctrl-\
            case 3: toggle(.osnap); return true // Ctrl-F
            case 5: toggle(.grid); return true // Ctrl-G
            case 11: toggle(.snap); return true // Ctrl-B
            case 32: toggle(.polar); return true // Ctrl-U
            case 37: toggle(.ortho); return true // Ctrl-L
            case 6: undo(); return true // Ctrl-Z
            case 16: redo(); return true // Ctrl-Y
            default: break
            }
        }
        switch event.keyCode {
        case 120: showCommandHistory.toggle(); showCommandLine = true // F2
        case 99: toggle(.osnap) // F3
        case 98: toggle(.grid) // F7
        case 100: toggle(.ortho) // F8
        case 101: toggle(.snap) // F9
        case 109: toggle(.polar) // F10
        case 111: toggle(.dynamicInput) // F12
        default: return false
        }
        return true
    }
}
