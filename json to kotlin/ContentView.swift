//
//  ContentView.swift
//  json to kotlin
//
//  Created by Pisey Nguon on 28/5/26.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#endif

struct ContentView: View {
    @State private var jsonInput: String = ""
    @State private var kotlinOutput: String = ""
    @State private var rootClassName: String = "Root"
    @State private var forceNullableNested: Bool = true
    @State private var classMode: ClassMode = .nested
    @State private var annotationMode: AnnotationMode = .none
    @State private var ignoredKeys: String = ""
    @State private var status: String = "Ready"
    @State private var autoConvertWorkItem: DispatchWorkItem?

    var body: some View {
        VStack(spacing: 8) {
            // Top controls
            HStack(spacing: 12) {
                Text("Root Class Name:")
                TextField("Root", text: $rootClassName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 240)

                Toggle("Force nullable on nested class fields", isOn: $forceNullableNested)
                    .toggleStyle(.switch)

                Spacer()

                Button("Convert") { convert(isAutomatic: false) }
                Button("Load JSON", action: loadJSONFile)
                Button("Save Kotlin", action: saveKotlinFile)
                Button("Copy Output", action: copyOutput)
                Button("Clear", action: clearAll)
            }
            .padding(.horizontal)

            // Options row
            HStack(spacing: 16) {
                HStack {
                    Text("Class Style:")
                    Picker("Class Style", selection: $classMode) {
                        Text("nested").tag(ClassMode.nested)
                        Text("top-level").tag(ClassMode.topLevel)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 260)
                }

                HStack {
                    Text("Annotations:")
                    Picker("Annotations", selection: $annotationMode) {
                        Text("none").tag(AnnotationMode.none)
                        Text("gson").tag(AnnotationMode.gson)
                        Text("moshi").tag(AnnotationMode.moshi)
                    }
                    .pickerStyle(.segmented)
                    .frame(maxWidth: 300)
                }

                HStack {
                    Text("Ignore keys (comma):")
                    TextField("e.g. meta,_links", text: $ignoredKeys)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                }

                Spacer()
            }
            .padding(.horizontal)

            // Split editors
            HStack(spacing: 8) {
                VStack(alignment: .leading) {
                    Text("JSON Input").font(.caption).foregroundStyle(.secondary)
                    #if os(macOS)
                    EditableCodeView(text: $jsonInput)
                        .overlay(
                            RoundedRectangle(cornerRadius: 0)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                        .frame(minHeight: 200)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #else
                    TextEditor(text: $jsonInput)
                        .font(.system(.body, design: .monospaced))
                        .border(.quaternary)
                        .frame(minHeight: 200)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #endif
                }
                VStack(alignment: .leading) {
                    Text("Kotlin Output").font(.caption).foregroundStyle(.secondary)
                    #if os(macOS)
                    ReadOnlyCodeView(text: kotlinOutput)
                        .overlay(
                            RoundedRectangle(cornerRadius: 0)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                        .frame(minHeight: 200)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #else
                    TextEditor(text: .constant(kotlinOutput))
                        .font(.system(.body, design: .monospaced))
                        .disabled(true)
                        .border(.quaternary)
                        .frame(minHeight: 200)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    #endif
                }
            }
            .padding(.horizontal)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            HStack {
                Text(status)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .padding([.horizontal, .bottom])
        }
        .onChange(of: jsonInput) { _ in
            scheduleAutoConvert()
        }
        .onChange(of: rootClassName) { _ in
            scheduleAutoConvert()
        }
        .onChange(of: forceNullableNested) { _ in
            scheduleAutoConvert()
        }
        .onChange(of: classMode) { _ in
            scheduleAutoConvert()
        }
        .onChange(of: annotationMode) { _ in
            scheduleAutoConvert()
        }
        .onChange(of: ignoredKeys) { _ in
            scheduleAutoConvert()
        }
    }

    private func scheduleAutoConvert() {
        autoConvertWorkItem?.cancel()

        if jsonInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            kotlinOutput = ""
            if status != "Cleared" {
                status = "Ready"
            }
            return
        }

        let workItem = DispatchWorkItem {
            convert(isAutomatic: true)
        }
        autoConvertWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: workItem)
    }

    private func convert(isAutomatic: Bool) {
        let ignored = Set(ignoredKeys.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty })
        let options = KotlinGeneratorOptions(
            rootClassName: rootClassName,
            forceNullableNested: forceNullableNested,
            classMode: classMode,
            annotationMode: annotationMode,
            ignoredKeys: ignored
        )
        do {
            kotlinOutput = try KotlinGenerator.generate(jsonText: jsonInput, options: options)
            status = "Kotlin data classes generated"
        } catch {
            if isAutomatic {
                status = "Waiting for valid JSON..."
            } else {
                kotlinOutput = ""
                status = error.localizedDescription
            }
        }
    }

    private func copyOutput() {
        #if os(iOS)
        UIPasteboard.general.string = kotlinOutput
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(kotlinOutput, forType: .string)
        #endif
        status = kotlinOutput.isEmpty ? "No output to copy" : "Kotlin output copied to clipboard"
    }

    private func loadJSONFile() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Select JSON file"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json, .plainText]
        let result = panel.runModal()
        guard result == .OK, let url = panel.url else {
            return
        }

        do {
            jsonInput = try String(contentsOf: url, encoding: .utf8)
            status = "Loaded: \(url.lastPathComponent)"
        } catch {
            status = "Failed to load file"
        }
        #else
        status = "Load JSON is available on macOS build"
        #endif
    }

    private func saveKotlinFile() {
        let output = kotlinOutput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !output.isEmpty else {
            status = "Nothing to save"
            return
        }

        #if os(macOS)
        let panel = NSSavePanel()
        panel.title = "Save Kotlin file"
        panel.nameFieldStringValue = "Output.kt"
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true
        let result = panel.runModal()
        guard result == .OK, let url = panel.url else {
            return
        }

        do {
            try (output + "\n").write(to: url, atomically: true, encoding: .utf8)
            status = "Saved: \(url.lastPathComponent)"
        } catch {
            status = "Failed to save Kotlin file"
        }
        #else
        status = "Save Kotlin is available on macOS build"
        #endif
    }

    private func clearAll() {
        autoConvertWorkItem?.cancel()
        jsonInput = ""
        kotlinOutput = ""
        status = "Cleared"
    }
}

#if os(macOS)
private struct EditableCodeView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.delegate = context.coordinator
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )

        // Keep JSON input literal by disabling typographic substitutions.
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else {
            return
        }
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: EditableCodeView

        init(parent: EditableCodeView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            if parent.text != textView.string {
                parent.text = textView.string
            }
        }
    }
}

private struct ReadOnlyCodeView: NSViewRepresentable {
    let text: String

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true

        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.usesFindBar = true
        textView.drawsBackground = false
        textView.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textView.textContainerInset = NSSize(width: 6, height: 8)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = true
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = false
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView else {
            return
        }
        if textView.string != text {
            textView.string = text
        }
    }
}
#endif

#Preview {
    ContentView()
}
