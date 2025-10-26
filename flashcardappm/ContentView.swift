import SwiftUI
import Combine
import UniformTypeIdentifiers

// MARK: - Models
struct Flashcard: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var question: String
    var answer: String

    init(id: UUID = UUID(), question: String, answer: String) {
        self.id = id
        self.question = question
        self.answer = answer
    }
}

struct Deck: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    var name: String
    var cards: [Flashcard]

    init(id: UUID = UUID(), name: String, cards: [Flashcard] = []) {
        self.id = id
        self.name = name
        self.cards = cards
    }
}

// MARK: - Persistence
final class DeckStore: ObservableObject {
    @Published var decks: [Deck] = []

    private var cancellables = Set<AnyCancellable>()
    private let url: URL

    init(filename: String = "decks.json") {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        self.url = docs.appendingPathComponent(filename)
        load()
        // Auto-save on any change with light debounce
        $decks
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    func load() {
        if let data = try? Data(contentsOf: url) {
            do {
                let decoded = try JSONDecoder().decode([Deck].self, from: data)
                self.decks = decoded
            } catch {
                print("Decode error: \(error)")
                seedIfEmpty()
            }
        } else {
            seedIfEmpty()
            save()
        }
    }

    func save() {
        do {
            let data = try JSONEncoder().encode(decks)
            try data.write(to: url, options: .atomic)
        } catch {
            print("Save error: \(error)")
        }
    }

    private func seedIfEmpty() {
        guard decks.isEmpty else { return }
        decks = [
            Deck(name: "Örnek Ders" , cards: [
                Flashcard(question: "Türkiye'nin başkenti?", answer: "Ankara"),
                Flashcard(question: "H2O nedir?", answer: "Su"),
                Flashcard(question: "2 + 2?", answer: "4")
            ])
        ]
    }

    // CRUD helpers
    func addDeck(name: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        decks.append(Deck(name: name))
    }

    func deleteDecks(at offsets: IndexSet) { decks.remove(atOffsets: offsets) }

    func addCard(to deckID: Deck.ID, question: String, answer: String) {
        guard let idx = decks.firstIndex(where: { $0.id == deckID }) else { return }
        let card = Flashcard(question: question, answer: answer)
        let insertIndex = Int.random(in: 0...decks[idx].cards.count)
        decks[idx].cards.insert(card, at: insertIndex)
        decks[idx].cards.shuffle()
    }

    func replaceCards(of deckID: Deck.ID, with cards: [Flashcard]) {
        guard let idx = decks.firstIndex(where: { $0.id == deckID }) else { return }
        decks[idx].cards = cards
    }
}

// MARK: - CSV Import/Export
struct CSV {
    /// Beklenen ayırıcı: ';' — ilk iki sütun question,answer (başlık varsa soru/cevap kabul edilir).
    static func parse(_ rawText: String) -> [Flashcard] {
        let text = stripBOM(rawText)
        let delimiter: Character = ";" // sabit noktalı virgül
        let rows = splitCSV(text, delimiter: delimiter)
        guard !rows.isEmpty else { return [] }

        var start = 0
        if rows.first!.count >= 2, looksLikeHeader(rows[0]) {
            start = 1
        }

        var cards: [Flashcard] = []
        for i in start..<rows.count {
            let cols = rows[i]
            guard cols.count >= 2 else { continue }
            let q = cols[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let a = cols[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if !q.isEmpty && !a.isEmpty {
                cards.append(Flashcard(question: q, answer: a))
            }
        }
        return cards
    }

    static func make(from cards: [Flashcard]) -> String {
        // Dışa aktarımı da noktalı virgül ile yapalım
        var out = "soru;cevap\n"
        for c in cards {
            out += "\(escape(c.question));\(escape(c.answer))\n"
        }
        return out
    }

    // --- helpers ---
    private static func stripBOM(_ s: String) -> String {
        if s.hasPrefix("\u{FEFF}") {
            return String(s.dropFirst())
        }
        return s
    }

    private static func looksLikeHeader(_ cols: [String]) -> Bool {
        guard cols.count >= 2 else { return false }
        let h0 = cols[0].lowercased()
        let h1 = cols[1].lowercased()
        let qWords = ["question", "soru", "prompt", "q"]
        let aWords = ["answer", "cevap", "a"]
        let firstIsQ = qWords.contains { h0.contains($0) }
        let secondIsA = aWords.contains { h1.contains($0) }
        // ters sıra da kabul
        let firstIsA = aWords.contains { h0.contains($0) }
        let secondIsQ = qWords.contains { h1.contains($0) }
        return (firstIsQ && secondIsA) || (firstIsA && secondIsQ)
    }

    private static func escape(_ s: String) -> String {
        // Noktalı virgül, satırsonu veya çift tırnak içeriyorsa kaçışla
        if s.contains(";") || s.contains("\n") || s.contains("\"") || s.contains("\r") {
            let escaped = s.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        } else { return s }
    }

    /// Tırnakları destekleyen basit CSV ayrıştırıcı (sabit ayırıcı: ';').
    private static func splitCSV(_ text: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var inQuotes = false
        var it = text.makeIterator()
        var prev: Character? = nil

        while let ch = it.next() {
            if inQuotes {
                if ch == "\"" {
                    if let p = it.peek(), p == "\"" {
                        _ = it.next()
                        field.append("\"")
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(ch)
                }
            } else {
                switch ch {
                case delimiter:
                    row.append(field)
                    field = ""
                case "\n", "\r":
                    // CRLF ve CR/LF normalize
                    if !(prev == "\r" && ch == "\n") {
                        row.append(field)
                        rows.append(row)
                        row = []
                        field = ""
                    }
                case "\"":
                    inQuotes = true
                default:
                    field.append(ch)
                }
            }
            prev = ch
        }
        row.append(field)
        if !row.isEmpty { rows.append(row) }
        return rows.filter { !$0.joined().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }
}

private extension String.Iterator {
    mutating func peek() -> Character? {
        var copy = self
        return copy.next()
    }
}

// MARK: - ViewModels per screen
final class DeckSessionViewModel: ObservableObject {
    @Published var working: [Flashcard] = []
    @Published var showingAnswer = false

    init(deck: Deck) {
        self.working = deck.cards
        self.working.shuffle()
    }

    var currentCard: Flashcard? { working.first }
    var isEmpty: Bool { working.isEmpty }

    func reveal() { withAnimation { showingAnswer = true } }
    func done() { guard !working.isEmpty else { return }; withAnimation { _ = working.removeFirst(); showingAnswer = false } }
    func notYet() { guard !working.isEmpty else { return }; withAnimation { let c = working.removeFirst(); working.append(c); showingAnswer = false } }
}

// MARK: - Views
struct DeckListView: View {
    @EnvironmentObject var store: DeckStore
    @State private var newDeckName = ""
    @State private var importingForDeck: Deck? = nil
    @State private var isExporting = false
    @State private var exportText: String = ""

    // Common allowed content types including generic CSV extension
    private var allowedImportTypes: [UTType] {
        var types: [UTType] = []
        if let csv = UTType(filenameExtension: "csv") { types.append(csv) }
        types += [.commaSeparatedText, .plainText]
        types.append(.text)
        types.append(.data)
        return types
    }

    var body: some View {
        NavigationView {
            List {
                Section(header: Text("Klasörler (Decks)")) {
                    ForEach(store.decks) { deck in
                        NavigationLink(destination: DeckDetailView(deck: deck)) {
                            HStack {
                                Image(systemName: "folder.fill")
                                Text(deck.name)
                                Spacer()
                                Text("\(deck.cards.count) kart")
                                    .foregroundStyle(.secondary)
                                    .font(.footnote)
                            }
                        }
                        .contextMenu {
                            Button("CSV içe aktar") { importingForDeck = deck }
                            Button("CSV dışa aktar") {
                                exportText = CSV.make(from: deck.cards)
                                isExporting = true
                            }
                        }
                    }
                    .onDelete(perform: store.deleteDecks)
                }

                Section(header: Text("Yeni klasör oluştur")) {
                    HStack {
                        TextField("Örn. ‘Entomoloji – Vize’", text: $newDeckName)
                        Button("Ekle") {
                            store.addDeck(name: newDeckName)
                            newDeckName = ""
                        }
                        .disabled(newDeckName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                }
            }
            .navigationTitle("Flashcards")
            .toolbar {
                ToolbarItem {
                    Button(action: {}) {
                        Image(systemName: "gear")
                    }
                }
            }
            // Ensure the window is a reasonable size on macOS so sheets (like fileImporter) are usable.
            .onAppear {
                #if os(macOS)
                if let window = NSApplication.shared.windows.first {
                    let minSize = NSSize(width: 700, height: 500)
                    window.setContentSize(minSize)
                    window.minSize = minSize
                }
                #endif
            }
        }
        .fileImporter(
            isPresented: Binding(get: { importingForDeck != nil }, set: { if !$0 { importingForDeck = nil } }),
            allowedContentTypes: allowedImportTypes,
            allowsMultipleSelection: false
        ) { res in
            print("Importer (DeckList) callback fired")
            guard let deck = importingForDeck else { return }
            do {
                let urls = try res.get()
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                print("Import (DeckList) read \(data.count) bytes from \(url.lastPathComponent)")
                let text = CSVTextDecoder.decode(data)
                guard let text else {
                    print("Import (DeckList) failed to decode text")
                    return
                }
                let cards = CSV.parse(text)
                print("Import (DeckList) parsed \(cards.count) cards")
                guard !cards.isEmpty else { return }
                let merged = (store.decks.first { $0.id == deck.id }?.cards ?? []) + cards
                store.replaceCards(of: deck.id, with: merged.shuffled())
            } catch {
                print("Import (DeckList) error: \(error)")
            }
            importingForDeck = nil
        }
        .fileExporter(isPresented: $isExporting, document: TextFile(text: exportText), contentType: .commaSeparatedText, defaultFilename: "flashcards.csv") { _ in }
    }
}

// A simple FileDocument for exporting text/CSV
struct TextFile: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText, .commaSeparatedText] }
    var text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        if let data = configuration.file.regularFileContents, let s = String(data: data, encoding: .utf8) { text = s } else { text = "" }
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { .init(regularFileWithContents: text.data(using: .utf8)!) }
}

struct DeckDetailView: View {
    @EnvironmentObject var store: DeckStore
    let deck: Deck
    @StateObject private var sessionVM: DeckSessionViewModel
    @State private var showingAdd = false

    // Added state to trigger import from inside deck detail
    @State private var importingHere = false

    // Common allowed content types including generic CSV extension
    private var allowedImportTypes: [UTType] {
        var types: [UTType] = []
        if let csv = UTType(filenameExtension: "csv") { types.append(csv) }
        types += [.commaSeparatedText, .plainText]
        types.append(.text)
        types.append(.data)
        return types
    }

    init(deck: Deck) {
        self.deck = deck
        _sessionVM = StateObject(wrappedValue: DeckSessionViewModel(deck: deck))
    }

    var body: some View {
        VStack(spacing: 16) {
            if sessionVM.isEmpty {
                ContentUnavailableView("Kart yok", systemImage: "rectangle.on.rectangle.slash", description: Text("Yeni kart ekle ya da CSV içe aktar."))
            } else {
                FlashcardView(card: sessionVM.currentCard!, showingAnswer: sessionVM.showingAnswer)
                    .padding(.horizontal)

                Button(action: sessionVM.reveal) {
                    Image(systemName: "chevron.down.circle.fill")
                        .font(.system(size: 56, weight: .bold))
                        .padding(8)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)

                if sessionVM.showingAnswer {
                    HStack(spacing: 12) {
                        Button { sessionVM.notYet() } label: { Label("Not yet", systemImage: "arrow.uturn.right") }
                            .buttonStyle(.bordered).tint(.orange)
                        Button { sessionVM.done() } label: { Label("Done", systemImage: "checkmark") }
                            .buttonStyle(.borderedProminent).tint(.green)
                    }
                    .transition(.opacity .combined(with: .move(edge: .bottom)))
                }

                HStack {
                    Text("Kalan: \(sessionVM.working.count)").font(.footnote).foregroundStyle(.secondary)
                    Spacer()
                    Button("Karıştır") { withAnimation { sessionVM.working.shuffle() } }
                }
                .padding(.horizontal)
            }
        }
        .navigationTitle(deck.name)
        .toolbar {
            ToolbarItem {
                Button { showingAdd = true } label: { Image(systemName: "plus") }
            }
            // Add a visible Import CSV button in the toolbar
            ToolbarItem {
                Button {
                    importingHere = true
                } label: {
                    Label("CSV içe aktar", systemImage: "tray.and.arrow.down")
                }
            }
        }
        // A local fileImporter that targets this deck directly
        .fileImporter(
            isPresented: $importingHere,
            allowedContentTypes: allowedImportTypes,
            allowsMultipleSelection: false
        ) { res in
            print("Importer (Detail) callback fired")
            do {
                let urls = try res.get()
                guard let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let data = try Data(contentsOf: url)
                print("Import (Detail) read \(data.count) bytes from \(url.lastPathComponent)")
                let text = CSVTextDecoder.decode(data)
                guard let text else {
                    print("Import (Detail) failed to decode text")
                    return
                }
                let cards = CSV.parse(text)
                print("Import (Detail) parsed \(cards.count) cards")
                guard !cards.isEmpty else { return }
                let merged = (store.decks.first { $0.id == deck.id }?.cards ?? []) + cards
                store.replaceCards(of: deck.id, with: merged.shuffled())
                refreshFromStore()
            } catch {
                print("Import (Detail) error: \(error)")
            }
        }
        .sheet(isPresented: $showingAdd) {
            AddCardSheetForDeck(deckID: deck.id)
                .environmentObject(store)
                .onDisappear { refreshFromStore() }
        }
        // Auto-refresh whenever the store's decks change (e.g., import from list while this view is on screen)
        .onReceive(store.$decks) { _ in
            refreshFromStore()
        }
        .onAppear { refreshFromStore() }
    }

    private func refreshFromStore() {
        if let updated = store.decks.first(where: { $0.id == deck.id }) {
            sessionVM.working = updated.cards.shuffled()
            sessionVM.showingAnswer = false
        }
    }
}

struct AddCardSheetForDeck: View {
    @EnvironmentObject var store: DeckStore
    let deckID: Deck.ID
    @Environment(\.dismiss) private var dismiss

    @State private var q = ""
    @State private var a = ""

    var body: some View {
        NavigationView {
            Form {
                Section("Soru") { TextField("Örn. 'Latince ad nedir?'", text: $q, axis: .vertical).lineLimit(3, reservesSpace: true) }
                Section("Cevap") { TextField("Örn. 'Apiaceae'", text: $a, axis: .vertical).lineLimit(5, reservesSpace: true) }
            }
            .navigationTitle("Yeni Kart")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Kapat") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Ekle") {
                        store.addCard(to: deckID, question: q, answer: a)
                        q = ""; a = ""; dismiss()
                    }
                    .disabled(q.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || a.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}

struct FlashcardView: View {
    let card: Flashcard
    let showingAnswer: Bool

    var body: some View {
        VStack(spacing: 16) {
            Text(card.question)
                .font(.title2.weight(.semibold))
                .multilineTextAlignment(.center)
            if showingAnswer {
                Divider()
                Text(card.answer)
                    .font(.title3)
                    .multilineTextAlignment(.center)
                    .transition(.opacity)
            } else {
                Text("⬇︎ Cevabı görmek için oka dokun")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(24)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
                .shadow(color: .black.opacity(0.15), radius: 20, x: 0, y: 12)
        )
    }
}

// Helper to try multiple encodings commonly seen in CSV exports
enum CSVTextDecoder {
    static func decode(_ data: Data) -> String? {
        if let s = String(data: data, encoding: .utf8) { return s }
        if let s = String(data: data, encoding: .unicode) { return s } // UTF-16 (platform endian)
        if let s = String(data: data, encoding: .utf16LittleEndian) { return s }
        if let s = String(data: data, encoding: .utf16BigEndian) { return s }
        if let s = String(data: data, encoding: .isoLatin1) { return s }
        // Attempt Windows-1254 (Turkish) if available via CFString
        #if canImport(CoreFoundation)
        if let s = data.withUnsafeBytes({ rawBuf -> String? in
            guard let base = rawBuf.baseAddress else { return nil }
            let cfStr = CFStringCreateWithBytes(kCFAllocatorDefault, base.assumingMemoryBound(to: UInt8.self), data.count, CFStringEncoding(CFStringEncodings.windowsLatin5.rawValue), false)
            return cfStr as String?
        }) { return s }
        #endif
        return nil
    }
}
