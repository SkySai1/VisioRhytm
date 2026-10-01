import AppKit
import SwiftUI

/// NSTextView provides the caret geometry and native Undo needed for inline completion.
struct LyricsTextEditor: NSViewRepresentable {
    @Binding var text: String
    let assistant: RhymeAssistant
    let presentation: RhymePresentation

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 240, height: 200))
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        let editor = NSTextView(frame: NSRect(origin: .zero, size: scroll.contentSize))
        editor.isRichText = false
        editor.isEditable = true
        editor.isSelectable = true
        editor.allowsUndo = true
        editor.isAutomaticQuoteSubstitutionEnabled = false
        editor.isAutomaticDashSubstitutionEnabled = false
        editor.isAutomaticTextReplacementEnabled = false
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textColor = .labelColor
        editor.drawsBackground = false
        editor.textContainerInset = NSSize(width: 8, height: 8)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.minSize = NSSize(width: 0, height: 0)
        editor.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: scroll.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
        editor.string = text
        editor.delegate = context.coordinator
        editor.textStorage?.delegate = context.coordinator
        editor.setAccessibilityLabel("Исходный текст песни")
        scroll.documentView = editor
        context.coordinator.editor = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.parent = self
        guard let editor = coordinator.editor else { return }
        if editor.string != text {
            coordinator.isUpdating = true
            let selection = editor.selectedRange()
            editor.string = text
            editor.undoManager?.removeAllActions()
            let count = (text as NSString).length
            editor.setSelectedRange(NSRange(location: min(selection.location, count), length: 0))
            coordinator.isUpdating = false
            Task { @MainActor [weak coordinator] in
                guard let coordinator, let editor = coordinator.editor else { return }
                coordinator.parent.assistant.updateEditor(text: editor.string, selection: editor.selectedRange())
            }
        }
        coordinator.updatePopover()
    }
    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) { coordinator.dispose() }

    // This storage belongs exclusively to a main-thread NSTextView.
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate, @preconcurrency NSTextStorageDelegate {
        var parent: LyricsTextEditor
        weak var editor: NSTextView?
        var isUpdating = false
        let popover = NSPopover()
        init(_ parent: LyricsTextEditor) {
            self.parent = parent
            super.init()
            popover.behavior = .applicationDefined
            popover.animates = false
            NotificationCenter.default.addObserver(self, selector: #selector(keyWindowChanged(_:)),
                name: NSWindow.didBecomeKeyNotification, object: nil)
        }
        func dispose() {
            NotificationCenter.default.removeObserver(self)
            popover.close()
        }
        @objc private func keyWindowChanged(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            if window !== editor?.window, window !== popover.contentViewController?.view.window { popover.close() }
        }
        func textDidChange(_ notification: Notification) {
            guard !isUpdating, let editor else { return }
            parent.text = editor.string
            updateSelection()
        }
        func textStorage(_ textStorage: NSTextStorage, didProcessEditing editedMask: NSTextStorageEditActions, range editedRange: NSRange, changeInLength delta: Int) {
            // Undo can update the storage without NSTextView's textDidChange delegate callback.
            guard !isUpdating, editedMask.contains(.editedCharacters), let editor else { return }
            parent.text = textStorage.string
            parent.assistant.updateEditor(text: textStorage.string,
                selection: editor.hasMarkedText() ? NSRange(location: NSNotFound, length: 0) : editor.selectedRange())
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            if !isUpdating { updateSelection(); updatePopover() }
        }
        func textDidBeginEditing(_ notification: Notification) { updateSelection(); updatePopover() }
        private func updateSelection() {
            guard let editor else { return }
            let selection = editor.hasMarkedText() ? NSRange(location: NSNotFound, length: 0) : editor.selectedRange()
            parent.assistant.updateEditor(text: editor.string, selection: selection)
        }
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch NSStringFromSelector(commandSelector) {
            case "cancelOperation:" where popover.isShown:
                parent.assistant.dismissSuggestions(); popover.close(); return true
            case "insertTab:" where popover.isShown && !parent.assistant.presentation.suggestions.isEmpty:
                pick(parent.assistant.presentation.suggestions[0]); return true
            default: return false
            }
        }
        func pick(_ suffix: String) {
            guard let editor,
                  let edit = parent.assistant.accept(suffix, text: editor.string, selection: editor.selectedRange()) else { return }
            // insertText participates in NSTextView's editing, selection and Undo pipeline.
            editor.insertText(edit.replacement, replacementRange: edit.range)
            editor.undoManager?.setActionName("Завершение рифмы")
            editor.window?.makeFirstResponder(editor)
            popover.close()
        }
        func updatePopover() {
            guard let editor, parent.assistant.presentation.isVisible,
                  editor.window?.firstResponder === editor,
                  !editor.hasMarkedText() else { popover.close(); return }
            if let keyWindow = NSApplication.shared.keyWindow,
               keyWindow !== editor.window, keyWindow !== popover.contentViewController?.view.window {
                popover.close(); return
            }
            let selection = editor.selectedRange()
            guard selection.location != NSNotFound, selection.location <= (editor.string as NSString).length,
                  let window = editor.window else { popover.close(); return }
            let screen = editor.firstRect(forCharacterRange: NSRange(location: selection.location, length: 0), actualRange: nil)
            var rect = editor.convert(window.convertFromScreen(screen), from: nil)
            rect.size.width = max(2, rect.size.width)
            guard rect.intersects(editor.visibleRect) else { popover.close(); return }
            let content = RhymeSuggestionsView(assistant: parent.assistant, onPick: { [weak self] in self?.pick($0) })
            if let host = popover.contentViewController as? NSHostingController<RhymeSuggestionsView> { host.rootView = content }
            else { popover.contentViewController = NSHostingController(rootView: content) }
            if popover.isShown { popover.positioningRect = rect }
            else { popover.show(relativeTo: rect, of: editor, preferredEdge: .maxX) }
            if NSApplication.shared.isActive { window.makeKey() }
            window.makeFirstResponder(editor)
        }
    }
}

struct RhymeSuggestionsView: View {
    let assistant: RhymeAssistant
    let onPick: (String) -> Void
    var body: some View {
        let state = assistant.presentation
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Рифма · строка \(state.lineNumber ?? 1)").font(.headline)
                Spacer()
                Button { assistant.refresh() } label: { Image(systemName: "arrow.clockwise") }.help("Другие варианты")
                Button { assistant.dismissSuggestions() } label: { Image(systemName: "xmark") }.help("Закрыть, Esc")
            }.buttonStyle(.borderless)
            Text(state.prefix).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            if state.isGenerating {
                HStack { ProgressView().controlSize(.small); Text("Ollama подбирает окончания…").font(.caption) }
            }
            if let error = state.error { Text(error).font(.caption).foregroundStyle(.orange).textSelection(.enabled) }
            ForEach(Array(state.suggestions.enumerated()), id: \.offset) { index, suffix in
                Button { onPick(suffix) } label: {
                    HStack(alignment: .top) {
                        Text("\(index + 1)").foregroundStyle(.secondary).monospacedDigit()
                        Text(suffix).multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(8)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                }.buttonStyle(.plain)
            }
            if !state.suggestions.isEmpty { Text("Tab — первый вариант · Esc — закрыть").font(.caption2).foregroundStyle(.secondary) }
        }.padding(14).frame(width: 320)
    }
}
