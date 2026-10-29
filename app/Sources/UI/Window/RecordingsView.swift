import AppKit
import SwiftUI

/// Nahrávky: the list of recordings on the left, the selected one on the right.
///
/// The selection lives in the model (`selectedRecording`), so the menu bar panel and
/// notifications can open a specific recording. Folder URLs are compared with
/// `PipelineRunner.same`, because the same folder can arrive spelled differently.
struct RecordingsView: View {
    let model: AppModel

    @State private var search = ""
    @State private var toDelete: RecordingItem?

    var body: some View {
        // HSplitView = AppKit's split view: the divider between the list and the detail is draggable.
        HSplitView {
            list
                .frame(minWidth: 280, idealWidth: 320, maxWidth: 440)
            detail
                .frame(minWidth: 480, maxWidth: .infinity, maxHeight: .infinity)
        }
        .navigationTitle("Nahrávky")
        .searchable(text: $search, placement: .toolbar, prompt: "Hledat podle názvu nebo data")
        .toolbar {
            ToolbarItem {
                Button {
                    model.library.reload()
                } label: {
                    Label("Obnovit", systemImage: "arrow.clockwise")
                }
                .help("Znovu načíst složku s nahrávkami")
            }
        }
        .confirmationDialog(
            "Přesunout nahrávku do Koše?",
            isPresented: Binding(get: { toDelete != nil }, set: { if !$0 { toDelete = nil } }),
            presenting: toDelete
        ) { item in
            Button("Přesunout do Koše", role: .destructive) { model.deleteRecording(item) }
        } message: { item in
            Text("„\(item.title)“: zvuk, snímky a přepis. Poznámka v Obsidianu zůstane.")
        }
        .task {
            model.library.reload()
            ensureSelection()
        }
        .onChange(of: model.library.items.map(\.folder)) {
            ensureSelection()
        }
        .onChange(of: model.selectedRecording) {
            // Preselected from outside (panel, notification) before the library saw the folder.
            if selectedItem == nil, model.selectedRecording != nil {
                model.library.reload()
                ensureSelection()
            }
        }
    }

    // MARK: - List

    private var items: [RecordingItem] { model.library.items }

    private var selectedItem: RecordingItem? {
        guard let selected = model.selectedRecording else { return nil }
        return items.first { PipelineRunner.same($0.folder, selected) }
    }

    /// The list's selection, mapped onto the folder URLs the library uses.
    private var selection: Binding<URL?> {
        Binding(
            get: { selectedItem?.folder },
            set: { folder in
                if let folder {
                    model.selectedRecording = folder
                }
            })
    }

    /// Title, folder name, date and app; case- and diacritic-insensitive.
    private var filtered: [RecordingItem] {
        let query = search.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return items }
        return items.filter { item in
            var haystack = [item.title, item.folder.lastPathComponent]
            if let meta = item.meta {
                haystack.append(RecordingTexts.dateTime(meta.startedAt))
                haystack.append(RecordingTexts.longDate(meta.startedAt))
                haystack.append(model.sourceName(meta.source))
            }
            return haystack.contains { $0.localizedStandardContains(query) }
        }
    }

    private var list: some View {
        List(selection: selection) {
            ForEach(filtered) { item in
                RecordingRow(item: item, pipeline: model.pipeline)
                    .tag(item.folder)
                    .contextMenu {
                        RecordingActionMenu(model: model, item: item) { toDelete = item }
                    }
            }
        }
        .overlay {
            if filtered.isEmpty {
                if search.isEmpty {
                    ContentUnavailableView(
                        "Zatím žádné nahrávky", systemImage: "waveform",
                        description: Text("Nahrávky se objeví po prvním meetingu, který nahraješ."))
                } else {
                    ContentUnavailableView.search(text: search)
                }
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if let item = selectedItem {
            RecordingDetailView(model: model, item: item) { toDelete = item }
        } else {
            ContentUnavailableView(
                "Vyber nahrávku", systemImage: "waveform",
                description: Text(items.isEmpty
                    ? "Nahrávky se objeví po prvním meetingu, který nahraješ."
                    : "Vyber nahrávku v seznamu vlevo."))
        }
    }

    /// Nothing (or a vanished folder) selected: select the newest recording.
    private func ensureSelection() {
        guard selectedItem == nil, let first = items.first else { return }
        model.selectedRecording = first.folder
    }
}
