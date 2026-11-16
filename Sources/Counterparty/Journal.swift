import AppKit
import SwiftUI

// a note pinned to a bar and a price of a coin's chart
struct Note: Codable, Identifiable {
    let id: UUID
    let coin: String
    // the timeframe it was taken on, seconds per bar
    let timeframe: Int
    // start of the bar it points at, unix seconds
    let time: Int
    let price: Double
    // decimals the coin's prices were shown with
    let decimals: Int
    var text: String
    let created: Date
    // the bars around it when it was taken. history only reaches back 400 bars, so the note keeps
    // its own piece of the chart for the share card
    let bars: [Point]
}

func timeframeLabel(_ seconds: Int) -> String {
    seconds < 60 ? "\(seconds)s" : "\(seconds / 60)m"
}

// every note taken, and who takes them. notes live in application support as one json file,
// the avatar as a png next to it
@MainActor @Observable
final class Journal {
    // newest first
    private(set) var notes: [Note] = []
    var name: String {
        didSet { UserDefaults.standard.set(name, forKey: Self.nameKey) }
    }
    // nil draws the name's initials
    private(set) var avatar: NSImage?
    private(set) var error: String?
    // the note the share sheet is open for
    var sharing: Note?
    // a note picked in the sidebar, the chart scrolls to it and opens its card
    var focus: UUID?

    private static let folder = URL.applicationSupportDirectory.appending(path: "Counterparty")
    private static let file = folder.appending(path: "journal.json")
    private static let broken = folder.appending(path: "journal-broken.json")
    private static let avatarFile = folder.appending(path: "avatar.png")
    private static let nameKey = "journalName"

    init() {
        UserDefaults.standard.register(defaults: [Self.nameKey: NSFullUserName()])
        name = UserDefaults.standard.string(forKey: Self.nameKey)!
        avatar = NSImage(contentsOf: Self.avatarFile)
        guard FileManager.default.fileExists(atPath: Self.file.path) else { return }
        do {
            notes = try JSONDecoder().decode([Note].self, from: Data(contentsOf: Self.file))
        } catch {
            // set aside instead of overwritten by the next note
            try? FileManager.default.removeItem(at: Self.broken)
            try? FileManager.default.moveItem(at: Self.file, to: Self.broken)
            self.error = "The journal couldn't be read and was set aside as journal-broken.json. \(error.localizedDescription)"
        }
    }

    // a new note, or the new text of one that exists
    func save(_ note: Note) {
        if let index = notes.firstIndex(where: { $0.id == note.id }) {
            notes[index] = note
        } else {
            notes.insert(note, at: 0)
        }
        write()
    }

    func delete(_ id: UUID) {
        notes.removeAll { $0.id == id }
        write()
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try JSONEncoder().encode(notes).write(to: Self.file, options: .atomic)
            error = nil
        } catch {
            self.error = "The journal couldn't be saved: \(error.localizedDescription)"
        }
    }

    // keeps a square 256 point copy, so the picture survives the original moving
    func setAvatar(from url: URL) {
        do {
            guard let image = NSImage(contentsOf: url) else { throw CocoaError(.fileReadCorruptFile) }
            let side = min(image.size.width, image.size.height)
            let middle = CGRect(x: (image.size.width - side) / 2, y: (image.size.height - side) / 2, width: side, height: side)
            let square = NSImage(size: NSSize(width: 256, height: 256), flipped: false) { rect in
                image.draw(in: rect, from: middle, operation: .copy, fraction: 1)
                return true
            }
            guard let tiff = square.tiffRepresentation, let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            try png.write(to: Self.avatarFile, options: .atomic)
            avatar = NSImage(data: png)
            error = nil
        } catch {
            self.error = "\(url.lastPathComponent) couldn't be used as the avatar: \(error.localizedDescription)"
        }
    }

    func removeAvatar() {
        do {
            try FileManager.default.removeItem(at: Self.avatarFile)
            avatar = nil
            error = nil
        } catch {
            self.error = "The avatar couldn't be removed: \(error.localizedDescription)"
        }
    }
}

// the note taker's picture in a circle, or their initials until they pick one
struct Avatar: View {
    let journal: Journal
    let theme: Theme
    var size = 30.0

    var body: some View {
        Group {
            if let image = journal.avatar {
                Image(nsImage: image).resizable().scaledToFill()
            } else {
                let initials = String(journal.name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
                ZStack {
                    theme.colors.panel.color
                    theme.colors.accent.color.opacity(0.22)
                    Text(initials)
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundStyle(theme.colors.accent.color)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(.circle)
        .overlay(Circle().strokeBorder(theme.colors.border.color))
    }
}

// a note the way it reads everywhere: the avatar on the left, then who, where on the chart, and what.
// the content is the note's text, or the field it's written in
struct NoteCard<Content: View>: View {
    let note: Note
    let journal: Journal
    let theme: Theme
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Avatar(journal: journal, theme: theme)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(journal.name).font(theme.prose(0, weight: .semibold)).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(barTime(note.time, timeframe: note.timeframe))
                        .font(theme.mono(-2))
                        .foregroundStyle(theme.colors.muted.color)
                        .fixedSize()
                }
                HStack(spacing: 6) {
                    Text(note.coin).fontWeight(.semibold).foregroundStyle(theme.colors.accent.color)
                    Text(timeframeLabel(note.timeframe)).foregroundStyle(theme.colors.muted.color)
                    Text(price(note.price, decimals: note.decimals))
                }
                .font(theme.mono(-2))
                VStack(alignment: .leading, spacing: 6) {
                    content
                }
                .font(theme.prose())
                .lineSpacing(3)
                .padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .foregroundStyle(theme.colors.text.color)
    }
}

// the sidebar: every note taken, newest first, under the day it was written
struct JournalView: View {
    let journal: Journal
    let workspace: Workspace
    let theme: Theme

    @AppStorage(Keys.showIndicator) private var showIndicator = true
    @AppStorage(Keys.timeframe) private var timeframe = 60
    @State private var onlyCoin = false

    var body: some View {
        let coin = workspace.selected?.coin
        let notes = onlyCoin ? journal.notes.filter { $0.coin == coin } : journal.notes
        let days = Dictionary(grouping: notes) { Calendar.current.startOfDay(for: $0.created) }
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                CapsLabel("Journal", theme: theme, color: theme.colors.text)
                Text("\(notes.count)").font(theme.mono(-2)).foregroundStyle(theme.colors.muted.color)
                Spacer()
                RuleSegments(items: [false, true], selection: $onlyCoin, theme: theme) { only, _ in
                    Text(only ? (coin ?? "coin") : "all").font(theme.mono(-1))
                }
            }
            .padding(.horizontal, 14)
            .frame(height: 40)
            theme.colors.border.color.frame(height: 1)
            if let error = journal.error {
                Text(error)
                    .font(theme.mono(-1))
                    .foregroundStyle(theme.colors.statusDown.color)
                    .textSelection(.enabled)
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if notes.isEmpty {
                Text("No notes yet.\nRight-click the chart where something happens and write what you see.")
                    .font(theme.mono(-1))
                    .lineSpacing(3)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(theme.colors.muted.color)
                    .padding(24)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(days.keys.sorted(by: >), id: \.self) { day in
                            CapsLabel(day.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated).year()), theme: theme)
                                .padding(.horizontal, 14)
                                .padding(.top, 14)
                                .padding(.bottom, 6)
                            ForEach(days[day]!) { note in
                                JournalRow(note: note, journal: journal, theme: theme) { show(note) }
                            }
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(theme.colors.background.color)
    }

    // opens the note's coin and timeframe, then the chart scrolls to it
    private func show(_ note: Note) {
        guard workspace.coins.contains(where: { $0.symbol == note.coin }) else { return }
        workspace.open(note.coin, mode: .newTab)
        showIndicator = true
        timeframe = note.timeframe
        journal.focus = note.id
    }
}

// one note in the sidebar: click to see it on the chart, right click for the rest
private struct JournalRow: View {
    let note: Note
    let journal: Journal
    let theme: Theme
    let show: () -> Void

    // the text while it's being edited in place
    @State private var editing: String?
    @State private var hovering = false
    @FocusState private var writing: Bool

    var body: some View {
        NoteCard(note: note, journal: journal, theme: theme) {
            if let text = editing {
                TextField("", text: Binding(get: { text }, set: { editing = $0 }), axis: .vertical)
                    .textFieldStyle(.plain)
                    .focused($writing)
                    .onSubmit { save(text) }
                    .onExitCommand { editing = nil }
                    .onAppear { writing = true }
            } else {
                Text(note.text).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(hovering || editing != nil ? theme.colors.panel.color : .clear)
        .overlay(alignment: .bottom) { theme.colors.border.color.frame(height: 1).padding(.leading, 54) }
        .overlay(alignment: .bottomTrailing) {
            if hovering && editing == nil {
                Button {
                    journal.sharing = note
                } label: {
                    Image(systemName: "square.and.arrow.up")
                        .font(.system(size: 11))
                        .frame(width: 26, height: 26)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .foregroundStyle(theme.colors.accent.color)
                .help("Share as a picture")
                .padding(4)
            }
        }
        .contentShape(.rect)
        .onTapGesture { if editing == nil { show() } }
        .onHover { hovering = $0 }
        .contextMenu {
            Button("Show on Chart") { show() }
            Button("Share…") { journal.sharing = note }
            Button("Edit") { editing = note.text }
            Divider()
            Button("Delete", role: .destructive) { journal.delete(note.id) }
        }
    }

    // an emptied note keeps its old text
    private func save(_ text: String) {
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var changed = note
            changed.text = text
            journal.save(changed)
        }
        editing = nil
    }
}
