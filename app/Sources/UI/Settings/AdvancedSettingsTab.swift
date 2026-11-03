import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Pokročilé: menu bar look, logs and diagnostics, paths of the tools, config reload and restart.
struct AdvancedSettingsTab: View {
    let model: AppModel

    @State private var exporting = false
    @State private var openingLog = false
    @State private var diagnosticsMessage: (tone: Tone, text: String)?

    var body: some View {
        SettingsPane(model: model) {
            Section {
                Picker("Ikona v menu baru", selection: model.configBinding(\.menuBarIcon)) {
                    Text("Duch").tag("ghost")
                    Text("Symbol").tag("symbol")
                }
            } header: {
                Text("Vzhled")
            }

            Section {
                Toggle("Podrobné logování", isOn: model.configBinding(\.debugLogging))
                HStack {
                    Button("Otevřít logy") { openLog() }
                        .disabled(openingLog)
                    Button("Exportovat diagnostiku…") { exportDiagnostics() }
                        .disabled(exporting)
                    Button("Otevřít složku s daty") { NSWorkspace.shared.open(AppPaths.supportDirectory) }
                    if exporting || openingLog {
                        ProgressView().controlSize(.small)
                    }
                }
                if let diagnosticsMessage {
                    SettingsNote(tone: diagnosticsMessage.tone, text: diagnosticsMessage.text)
                }
            } header: {
                Text("Diagnostika")
            } footer: {
                SettingsFooter(
                    "Podrobné logování zapisuje signály detekce při každé kontrole. Export obsahuje nastavení, "
                        + "stav oprávnění, logy appky za poslední 2 hodiny a metadata tří posledních nahrávek. "
                        + "Nikdy ne přepisy, zvuk ani snímky.")
            }

            Section {
                CommitTextField(
                    "Složka pipeline", value: model.configBinding(\.pipelinePath),
                    prompt: AppConfig().resolvedPipelinePath())
                SettingsNote(tone: pipelineStatus.tone, text: pipelineStatus.text)
                CommitTextField(
                    "Cesta k uv", value: model.configBinding(\.uvPath), prompt: AppConfig().resolvedUVPath())
                SettingsNote(tone: uvStatus.tone, text: uvStatus.text)
                LabeledContent("Claude Code") {
                    SettingsNote(tone: claudeStatus.tone, text: claudeStatus.text)
                }
            } header: {
                Text("Cesty")
            } footer: {
                SettingsFooter(
                    "Prázdné = dohledá se samo: pipeline z repozitáře, ze kterého je appka sestavená, uv v "
                        + "~/.local/bin, ~/.cargo/bin, /opt/homebrew/bin nebo /usr/local/bin. Appka z menu "
                        + "baru nevidí PATH tvého shellu.")
            }

            Section {
                LabeledContent("config.json") {
                    Text(AppPaths.configFile.path(percentEncoded: false))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .textSelection(.enabled)
                }
                HStack {
                    Button("Znovu načíst config.json") { model.reloadConfig() }
                    Button("Restartovat appku") { AppRelauncher.relaunch() }
                }
            } header: {
                Text("Konfigurace")
            } footer: {
                SettingsFooter(
                    "config.json jde upravit i ručně; po úpravě ho znovu načti. Restart pomůže po udělení "
                        + "oprávnění Nahrávání obrazovky.")
            }
        }
        .onAppear { model.environment.refresh(config: model.config) }
    }

    // MARK: - Tool status

    private var pipelineStatus: (tone: Tone, text: String) {
        let environment = model.environment
        if !environment.pipelineFound {
            return (.error, "Pipeline nenalezena: v \(model.config.resolvedPipelinePath()) chybí pyproject.toml.")
        }
        if !environment.pipelineInstalled {
            return (.warning, "Pipeline nalezena, ale není nainstalovaná: spusť `uv sync` ve složce pipeline.")
        }
        return (.success, "Pipeline nalezena a nainstalovaná.")
    }

    private var uvStatus: (tone: Tone, text: String) {
        if let uv = model.environment.uvPath {
            return (.success, "uv nalezen: \(uv)")
        }
        return (.error, "uv nenalezen. Nainstaluj ho (curl -LsSf https://astral.sh/uv/install.sh | sh) nebo zadej cestu.")
    }

    private var claudeStatus: (tone: Tone, text: String) {
        if let claude = model.environment.claudePath {
            return (.success, "nalezen: \(claude)")
        }
        return (.warning, "nenalezen: poznámka vznikne jen s přepisem")
    }

    // MARK: - Diagnostics

    /// `log show` takes a few seconds: run it in the background and open the file when done.
    private func openLog() {
        openingLog = true
        diagnosticsMessage = nil
        Task {
            do {
                try await DiagnosticsExporter.openRecentLog()
            } catch {
                diagnosticsMessage = (.error, "Logy se nepodařilo načíst: \(error.localizedDescription)")
            }
            openingLog = false
        }
    }

    /// NSSavePanel is AppKit's standard "save as" dialog; it asks about replacing an existing file.
    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.nameFieldStringValue = DiagnosticsExporter.archiveName(for: .now) + ".zip"
        panel.message = "Kam uložit diagnostický balíček"
        panel.prompt = "Exportovat"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        // Copy what the summary needs while still on the main actor; the export runs off it.
        let snapshot = model.diagnosticsSnapshot
        exporting = true
        diagnosticsMessage = nil
        Task {
            do {
                let archive = try await DiagnosticsExporter.export(snapshot: snapshot, to: destination)
                diagnosticsMessage = (.success, "Diagnostika uložena: \(archive.lastPathComponent)")
                NSWorkspace.shared.activateFileViewerSelecting([archive])
            } catch {
                diagnosticsMessage = (.error, "Export se nepovedl: \(error.localizedDescription)")
            }
            exporting = false
        }
    }
}
