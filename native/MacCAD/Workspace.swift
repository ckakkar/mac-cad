import SwiftUI
import AppKit

/// The drawing area of a document window: model space, command line and status
/// bar. Tool Sets and the inspector live in the window's split view.
struct WorkspaceView: View {
    @Bindable var model: EditorModel
    var body: some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topLeading) {
                CanvasHost(model: model)
                ViewportControls(model: model).padding(8)
                if model.entityCount == 0 && !model.session.active { EmptyDrawingHint(model: model) }
            }
            .frame(minWidth: 420, minHeight: 300)
            // Expanded history and autocomplete float over model space, so the canvas never jumps.
            .overlay(alignment: .bottomLeading) {
                if model.showCommandLine {
                    VStack(alignment: .leading, spacing: 6) {
                        if model.showCommandHistory { HistoryList(model: model, lines: 300).frame(height: 220).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8)) }
                        if !model.suggestions.isEmpty { SuggestionList(model: model).frame(maxWidth: 460) }
                    }
                    .padding(8)
                }
            }
            .accessibilityElement(children: .contain)
            if model.showCommandLine { CommandLineView(model: model) }
            if model.showStatus { StatusBar(model: model) }
        }
        .onChange(of: model.grid) { model.invalidate?() }
        .onChange(of: model.lineWeights) { model.invalidate?() }
        .onChange(of: model.gridSnap) { model.invalidate?() }
        .onChange(of: model.dynamicInput) { model.invalidate?() }
        .task { await model.refresh() }
        .sheet(isPresented: $model.showCommandReference) { CommandReference(model: model) }
        .sheet(isPresented: $model.showDraftingSettings) { DraftingSettingsSheet(model: model) }
        .sheet(isPresented: $model.showUnits) { UnitsSheet(model: model) }
    }
}

/// AutoCAD's viewport control: the [–] menu holds view commands for this viewport.
private struct ViewportControls: View {
    @Bindable var model: EditorModel
    @Bindable var settings = AppSettings.shared
    var body: some View {
        HStack(spacing: 2) {
            Menu {
                Button("Zoom Extents") { model.fitView?() }
                Button("Zoom Window") { model.runFromMenu("ZOOM W") }
                Button("Zoom Previous") { model.previousView?() }
                Divider()
                Button("Regenerate") { model.invalidate?() }
                Divider()
                Toggle("Grid", isOn: $model.grid)
                Toggle("UCS Icon", isOn: $settings.showUCSIcon)
                Picker("Background", selection: $settings.background) { ForEach(AppSettings.Background.allCases) { Text($0.title).tag($0) } }
            } label: { Text("[–]") }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            .help("Viewport controls")
            Text("[Top]  [2D Wireframe]")
        }
        .font(.system(size: 11))
        .foregroundStyle(settings.background == .dark ? Color.white.opacity(0.7) : Color.black.opacity(0.6))
        .accessibilityLabel("Viewport controls")
    }
}

private struct EmptyDrawingHint: View {
    let model: EditorModel
    var body: some View {
        VStack(spacing: 6) {
            Text("Type a command, choose a tool, or").foregroundStyle(.secondary)
            Button("Open the Example Floor Plan") { model.demo() }.buttonStyle(.link)
        }
        .font(.callout)
        .padding(.horizontal, 16).padding(.vertical, 10)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 28)
    }
}

/// AutoCAD-style command line: recent history above the live prompt, whose
/// bracketed options are clickable, and autocomplete while typing a command.
struct CommandLineView: View {
    @Bindable var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Divider()
            // AutoCAD keeps a few recent lines above the prompt; F2 expands the full history.
            HistoryList(model: model, lines: 3).frame(height: 46).opacity(model.showCommandHistory ? 0 : 1)
            Divider().opacity(0.5)
            HStack(spacing: 6) {
                Button { model.showCommandHistory.toggle() } label: {
                    Image(systemName: model.showCommandHistory ? "chevron.down" : "chevron.up").font(.system(size: 9, weight: .semibold))
                }.buttonStyle(.borderless).help("Expand or collapse command history (F2)")
                Image(systemName: "chevron.right.2").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                PromptText(model: model)
                CommandInput(model: model).frame(minWidth: 140).frame(height: 20)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(Color(nsColor: .textBackgroundColor).opacity(0.6))
        }
        .background(.bar)
        .accessibilityElement(children: .contain).accessibilityLabel("Command line")
    }
}

private struct HistoryList: View {
    let model: EditorModel
    let lines: Int
    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 1) {
                    ForEach(model.commandHistory.suffix(lines)) { line in
                        Text(line.text)
                            .foregroundStyle(line.kind == .error ? Color.red : line.kind == .info ? Color.secondary : Color.primary.opacity(0.8))
                            .frame(maxWidth: .infinity, alignment: .leading).id(line.id)
                    }
                }
                .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                .padding(.horizontal, 10).padding(.vertical, 4)
            }
            .scrollIndicators(lines > 3 ? .automatic : .never)
            .onAppear { if let id = model.commandHistory.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
            .onChange(of: model.commandHistory.last?.id) { if let id = model.commandHistory.last?.id { proxy.scrollTo(id, anchor: .bottom) } }
        }
        .accessibilityLabel("Command history")
    }
}

private struct PromptText: View {
    let model: EditorModel
    var body: some View {
        let parts = CommandSession.options(in: model.session.prompt)
        HStack(spacing: 3) {
            Text(parts.lead.trimmingCharacters(in: .whitespaces)).lineLimit(1)
            ForEach(parts.options, id: \.self) { option in
                Button(option) { model.execute(option) }
                    .buttonStyle(OptionButtonStyle()).help("Choose \(option)")
            }
            if !parts.options.isEmpty { Text(parts.tail.trimmingCharacters(in: .whitespaces)).lineLimit(1) }
        }
        .font(.system(size: 12, design: .monospaced))
        .fixedSize()
        .layoutPriority(1)
    }
}
/// Clickable command option keywords, as in AutoCAD's command line.
private struct OptionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .padding(.horizontal, 4).padding(.vertical, 1)
            .foregroundStyle(Color.accentColor)
            .background(Color.accentColor.opacity(configuration.isPressed ? 0.3 : 0.14), in: RoundedRectangle(cornerRadius: 3))
    }
}

private struct SuggestionList: View {
    @Bindable var model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(model.suggestions.enumerated()), id: \.element) { index, name in
                Button { model.commandText = name; model.suggestionIndex = nil; model.submit() } label: {
                    HStack {
                        Text(name).font(.system(size: 12, design: .monospaced))
                        Spacer()
                        Text(CommandCatalog.entries[name] ?? "").foregroundStyle(.secondary).font(.system(size: 11))
                    }
                    .padding(.horizontal, 10).padding(.vertical, 3)
                    .contentShape(Rectangle())
                    .background(index == model.suggestionIndex ? Color.accentColor.opacity(0.25) : Color.clear)
                }.buttonStyle(.plain)
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.primary.opacity(0.12), lineWidth: 0.5))
        .shadow(radius: 6, y: 2)
        .accessibilityLabel("Command suggestions")
    }
}

struct CommandReference: View {
    let model: EditorModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("2D Command Reference").font(.title2.weight(.semibold))
            Text("Space/Return accepts prompts and repeats the last command when idle. Select before a modify tool or after invoking it. x,y is absolute; @x,y and @distance<angle are relative. Angles are degrees. Annotation spaces remain text. Click a grip to stretch it.").foregroundStyle(.secondary)
            ScrollView {
                Text("""
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
                DSETTINGS              LAYER / PROPERTIES
                """).font(.system(size: 11, design: .monospaced)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("Done") { model.showCommandReference = false }.keyboardShortcut(.defaultAction)
            }
        }.padding(24).frame(width: 670, height: 700)
    }
}
