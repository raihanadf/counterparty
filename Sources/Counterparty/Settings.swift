import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let themes: ThemeStore

    @State private var exportError: String?

    var body: some View {
        Form {
            Section("Theme") {
                // a swatch of each theme's background, candles and accent, click to switch
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10)], spacing: 10) {
                    ForEach(themes.choices, id: \.self) { choice in
                        swatch(choice)
                    }
                }
                .padding(.vertical, 4)
                if let error = themes.error ?? exportError {
                    Text(error).foregroundStyle(.red).textSelection(.enabled)
                }
            }

            Section("Imported theme") {
                LabeledContent("File") {
                    Text(themes.source?.path ?? "none").textSelection(.enabled).lineLimit(2).truncationMode(.middle)
                }
                HStack {
                    Button("Import Theme…") { importTheme() }
                    Button("Reload") { themes.reload() }
                        .disabled(themes.source == nil)
                        .help("Read the imported file again after editing it")
                    Spacer()
                    Button("Remove") { themes.removeImported() }
                        .disabled(themes.imported == nil)
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
        .frame(width: 560, height: 680)
    }

    private func swatch(_ choice: String) -> some View {
        let theme = choice == ThemeStore.custom ? themes.imported! : Theme.builtins.first { $0.name == choice }!
        let colors = theme.colors
        let selected = themes.choice == choice
        return Button {
            themes.choose(choice)
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                // a tiny chart: four candles and a volume strip on the theme's background
                HStack(alignment: .bottom, spacing: 4) {
                    ForEach(Array([(true, 18.0), (false, 12.0), (true, 24.0), (false, 9.0)].enumerated()), id: \.offset) { _, candle in
                        (candle.0 ? colors.candleUp : colors.candleDown).color.frame(width: 7, height: candle.1)
                    }
                    Spacer()
                    colors.accent.color.frame(width: 10, height: 10).clipShape(.circle)
                }
                .padding(8)
                .frame(height: 44)
                .background(colors.background.color, in: .rect(cornerRadius: 5))
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(colors.border.color))
                Text(themes.title(of: choice)).font(.caption).lineLimit(1)
            }
            .padding(5)
            .background(selected ? Color.accentColor.opacity(0.2) : .clear, in: .rect(cornerRadius: 7))
            .overlay(RoundedRectangle(cornerRadius: 7).stroke(selected ? Color.accentColor : .clear, lineWidth: 2))
        }
        .buttonStyle(.plain)
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
