import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    let themes: ThemeStore
    let updater: Updater

    @State private var exportError: String?

    var body: some View {
        let theme = themes.theme
        Form {
            updates(theme)

            Section {
                // a swatch of each theme's background, candles and accent, click to switch
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 112), spacing: 12)], spacing: 16) {
                    ForEach(themes.choices, id: \.self) { choice in
                        swatch(choice)
                    }
                }
                .padding(.vertical, 8)
                if let error = themes.error ?? exportError {
                    Text(error).foregroundStyle(theme.colors.statusDown.color).textSelection(.enabled)
                }
            } header: {
                CapsLabel("Theme", theme: theme)
            }

            Section {
                LabeledContent("File") {
                    Text(themes.source?.path ?? "none").font(theme.mono(-1)).textSelection(.enabled).lineLimit(2).truncationMode(.middle)
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
            } header: {
                CapsLabel("Imported theme", theme: theme)
            }

            Section {
                Text("""
                A theme is a .json file with the same keys as an exported theme: name, appearance, font, colors, show and layout. \
                Leave out anything you don't want to change. Colors are #rrggbb, #rrggbbaa, rgb() or rgba(). \
                Set a key under "show" to false to hide that part. Export the default theme for the full list.
                """)
                .foregroundStyle(theme.colors.muted.color)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            } header: {
                CapsLabel("Theme files", theme: theme)
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .background(theme.colors.background.color)
        .foregroundStyle(theme.colors.text.color)
        .tint(theme.colors.accent.color)
        .preferredColorScheme(theme.appearance == .light ? .light : .dark)
        .frame(width: 560, height: 680)
    }

    private func swatch(_ choice: String) -> some View {
        let theme = choice == ThemeStore.custom ? themes.imported! : Theme.builtins.first { $0.name == choice }!
        let colors = theme.colors
        let selected = themes.choice == choice
        let ring = themes.theme.colors
        // a tiny chart in the theme's own colours: five candles with their wicks, the accent ruled under them.
        // each is (up, where its wick starts, wick length, where its body starts inside the wick, body length)
        let candles: [(up: Bool, y: Double, wick: Double, inset: Double, body: Double)] = [
            (true, 14, 18, 4, 10), (true, 6, 20, 3, 12), (false, 4, 22, 6, 10), (false, 10, 18, 2, 12), (true, 2, 24, 6, 14)
        ]
        return Button {
            themes.choose(choice)
        } label: {
            VStack(alignment: .leading, spacing: 8) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 6) {
                        ForEach(Array(candles.enumerated()), id: \.offset) { _, candle in
                            ZStack(alignment: .top) {
                                (candle.up ? colors.wickUp : colors.wickDown).color.frame(width: 1, height: candle.wick)
                                (candle.up ? colors.candleUp : colors.candleDown).color
                                    .frame(width: 6, height: candle.body)
                                    .padding(.top, candle.inset)
                            }
                            .padding(.top, candle.y)
                            .frame(height: 34, alignment: .top)
                        }
                        Spacer(minLength: 0)
                    }
                    colors.accent.color.frame(width: 28, height: 1.5)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(colors.background.color, in: .rect(cornerRadius: 2))
                .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(colors.border.color))
                Text(themes.title(of: choice).uppercased())
                    .font(themes.theme.caps())
                    .tracking(1.2)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .foregroundStyle((selected ? ring.text : ring.muted).color)
            }
            .padding(6)
            .frame(maxHeight: .infinity, alignment: .top)
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(selected ? ring.accent.color : .clear, lineWidth: 1))
            .contentShape(.rect)
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

extension SettingsView {
    @ViewBuilder
    private func updates(_ theme: Theme) -> some View {
        @Bindable var updater = updater
        Section {
            if let current = updater.current {
                LabeledContent("Installed") { Text(current).font(theme.mono()) }
                LabeledContent("Status") {
                    HStack(spacing: 10) {
                        switch updater.phase {
                        case .idle: Text("not checked yet").foregroundStyle(theme.colors.muted.color)
                        case .checking: ProgressView().controlSize(.small)
                        case .upToDate: Text("up to date").foregroundStyle(theme.colors.muted.color)
                        case .available: Text("\(updater.latest!.version) available").foregroundStyle(theme.colors.accent.color)
                        case .installing: Text("installing…").foregroundStyle(theme.colors.accent.color)
                        case .failed(let reason): Text(reason).foregroundStyle(theme.colors.statusDown.color).textSelection(.enabled)
                        }
                        Button("Check Now") { Task { await updater.check() } }
                            .disabled(updater.phase == .checking || updater.phase == .installing)
                    }
                }
                Toggle("Check for updates automatically", isOn: $updater.automatic)
                if let release = updater.latest, updater.phase == .available || updater.phase == .installing {
                    UpdateNotes(release: release, theme: theme)
                    Button(updater.phase == .installing ? "Installing…" : "Install and Restart") {
                        Task { await updater.install() }
                    }
                    .disabled(updater.phase == .installing)
                }
            } else {
                Text("Running from source, there's no installed app to update. Build it with ./bundle.sh.")
                    .foregroundStyle(theme.colors.muted.color)
            }
        } header: {
            CapsLabel("Updates", theme: theme)
        }
    }
}

// the release's notes, as github shows them: inline markdown, line breaks kept
struct UpdateNotes: View {
    let release: Updater.Release
    let theme: Theme

    var body: some View {
        if let notes = release.notes {
            ScrollView {
                Text(LocalizedStringKey(notes))
                    .font(theme.mono(-1))
                    .foregroundStyle(theme.colors.text.color)
                    .lineSpacing(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
            }
            .frame(maxHeight: 220)
        }
    }
}

// the popup when a new version is out: what's new, install now or later
struct UpdatePrompt: View {
    let updater: Updater
    let release: Updater.Release
    let theme: Theme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 56, height: 56)
                VStack(alignment: .leading, spacing: 4) {
                    CapsLabel("Update available", theme: theme, color: theme.colors.accent)
                    Text("Counterparty \(release.version)").font(theme.mono(4, weight: .semibold))
                    Text("You have \(updater.current!).").foregroundStyle(theme.colors.muted.color)
                }
            }
            if release.notes != nil {
                theme.colors.border.color.frame(height: 1)
                CapsLabel("What's new", theme: theme)
                UpdateNotes(release: release, theme: theme)
            }
            if case .failed(let reason) = updater.phase {
                Text("Update failed: \(reason)").foregroundStyle(theme.colors.statusDown.color).textSelection(.enabled)
            }
            HStack {
                Text("The app restarts on its own, your tabs come back.")
                    .font(theme.mono(-2))
                    .foregroundStyle(theme.colors.muted.color)
                Spacer()
                Button("Later") { updater.later() }
                    .keyboardShortcut(.cancelAction)
                    .disabled(updater.phase == .installing)
                Button(updater.phase == .installing ? "Installing…" : "Install and Restart") {
                    Task { await updater.install() }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(updater.phase == .installing)
            }
        }
        .font(theme.mono(-1))
        .foregroundStyle(theme.colors.text.color)
        .padding(20)
        .frame(width: 460)
        .background(theme.colors.panel.color)
        .tint(theme.colors.accent.color)
        .preferredColorScheme(theme.appearance == .light ? .light : .dark)
    }
}
