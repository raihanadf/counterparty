import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let themes: ThemeStore

    @State private var exportError: String?

    var body: some View {
        Form {
            Section("Theme") {
                LabeledContent("Active", value: themes.theme.name)
                LabeledContent("File") {
                    Text(themes.source?.path ?? "built in").textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                if let error = themes.error ?? exportError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
                HStack {
                    Button("Import Theme…") { importTheme() }
                    Button("Reload") { themes.reload() }
                        .disabled(themes.source == nil)
                        .help("Read the imported file again after editing it")
                    Spacer()
                    Button("Reset to Default") { themes.reset() }
                        .disabled(themes.source == nil && themes.theme == .standard)
                }
                HStack {
                    Button("Export Current Theme…") { export(themes.theme) }
                    Button("Export Default Theme…") { export(.standard) }
                    Spacer()
                }
            }

            Section("Theme files") {
                Text("""
                A theme is a .json file with the same keys as an exported theme: name, appearance, font, colors, show and layout. \
                Leave out anything you don't want to change. Colors are #rrggbb, #rrggbbaa, rgb() or rgba(). \
                Set a key under "show" to false to hide that part. Export the default theme for the full list.
                """)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560)
    }

    private func importTheme() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a Counterparty theme"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        exportError = nil
        themes.importTheme(from: url)
    }

    private func export(_ theme: Theme) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "\(theme.name).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try theme.export().write(to: url, options: .atomic)
            exportError = nil
        } catch {
            exportError = "Export failed: \(error.localizedDescription)"
        }
    }
}
