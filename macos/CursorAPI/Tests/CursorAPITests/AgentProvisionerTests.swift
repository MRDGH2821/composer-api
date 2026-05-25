import CursorAPICore
import XCTest

final class AgentProvisionerTests: XCTestCase {
    func testInstallsOpenCodeProvider() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.opencode, settings: settings)

        let config = home.appending(path: ".config/opencode/opencode.json")
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("cursorapi"))
        XCTAssertTrue(text.contains("cursor-local"))
        XCTAssertTrue(text.contains("composer-2.5-fast"))
        XCTAssertTrue(provisioner.status(for: .opencode, settings: settings).installed)
    }

    func testInstallsCodexProvider() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.codex, settings: settings)

        let config = home.appending(path: ".codex/config.toml")
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("[model_providers.cursorapi]"))
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
        XCTAssertTrue(provisioner.status(for: .codex, settings: settings).installed)
    }

    func testCodexInstallUpdatesExistingProviderWithoutDuplicatingSections() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let config = home.appending(path: ".codex/config.toml")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        approval_policy = "on-request"

        [model_providers.cursorapi]
        name = "Old CursorAPI"
        base_url = "http://127.0.0.1:9999/v1"
        env_key = "OLD_KEY"

        [profiles.cursorapi]
        model_provider = "cursorapi"
        model = "old-model"

        [profiles.cursorapi-fast]
        model_provider = "cursorapi"
        model = "old-fast-model"

        [profiles.other]
        model_provider = "openai"
        model = "gpt-5"
        """.write(to: config, atomically: true, encoding: .utf8)

        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.codex, settings: settings)
        try provisioner.install(.codex, settings: settings)

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertEqual(countOccurrences(of: "[model_providers.cursorapi]", in: text), 1)
        XCTAssertEqual(countOccurrences(of: "[profiles.cursorapi]", in: text), 1)
        XCTAssertEqual(countOccurrences(of: "[profiles.cursorapi-fast]", in: text), 1)
        XCTAssertTrue(text.contains("approval_policy = \"on-request\""))
        XCTAssertTrue(text.contains("[profiles.other]"))
        XCTAssertTrue(text.contains("base_url = \"http://127.0.0.1:8787/v1\""))
        XCTAssertTrue(text.contains("wire_api = \"responses\""))
        XCTAssertFalse(text.contains("old-model"))
        XCTAssertFalse(text.contains("OLD_KEY"))
    }

    func testInstallsPiModels() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.pi, settings: settings)

        let config = home.appending(path: ".pi/agent/models.json")
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("openai-completions"))
        XCTAssertTrue(text.contains("cursor-local"))
        XCTAssertTrue(text.contains("cursorapi"))
        XCTAssertTrue(provisioner.status(for: .pi, settings: settings).installed)
    }

    func testInstallsClineAndKiloProfiles() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.cline, settings: settings)
        try provisioner.install(.kilo, settings: settings)

        let kiloConfig = home.appending(path: ".config/kilo/kilo.jsonc")
        let kiloText = try String(contentsOf: kiloConfig, encoding: .utf8)
        XCTAssertTrue(kiloText.contains("cursor-local"))
        XCTAssertTrue(provisioner.status(for: .cline, settings: settings).installed)
        XCTAssertTrue(provisioner.status(for: .kilo, settings: settings).installed)
    }

    func testKiloInstallReadsJSONCAndBacksUpExistingConfig() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        let config = home.appending(path: ".config/kilo/kilo.jsonc")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try """
        {
          // Kilo allows comments here.
          "$schema": "https://app.kilo.ai/config.json",
          "model": "other/provider",
          "provider": {
            "existing": {
              "options": {
                "baseURL": "http://localhost:1234/v1"
              }
            }
          }
        }
        """.write(to: config, atomically: true, encoding: .utf8)

        try provisioner.install(.kilo, settings: settings)

        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("\"existing\""))
        XCTAssertTrue(text.contains("\"cursorapi\""))
        XCTAssertTrue(text.contains("cursor-local"))

        let backups = try FileManager.default.contentsOfDirectory(at: config.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("kilo.jsonc.cursorapi-backup.") }
        XCTAssertEqual(backups.count, 1)
        let backupText = try String(contentsOf: backups[0], encoding: .utf8)
        XCTAssertTrue(backupText.contains("Kilo allows comments"))
    }

    func testInstallBacksUpChangedJSONConfig() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        let config = home.appending(path: ".config/opencode/opencode.json")
        try FileManager.default.createDirectory(at: config.deletingLastPathComponent(), withIntermediateDirectories: true)
        try #"{"model":"other/model","provider":{"other":{"name":"Other"}}}"#.write(to: config, atomically: true, encoding: .utf8)

        try provisioner.install(.opencode, settings: settings)

        let backups = try FileManager.default.contentsOfDirectory(at: config.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("opencode.json.cursorapi-backup.") }
        XCTAssertEqual(backups.count, 1)
        let backupText = try String(contentsOf: backups[0], encoding: .utf8)
        XCTAssertTrue(backupText.contains("other/model"))
    }

    func testInstallsVSCodeModelMetadata() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let settings = CursorAPISettings(port: 8787)
        try provisioner.install(.vscode, settings: settings)

        let config = home.appending(path: "Library/Application Support/Code/User/chatLanguageModels.json")
        let text = try String(contentsOf: config, encoding: .utf8)
        XCTAssertTrue(text.contains("CursorAPI"))
        XCTAssertTrue(text.contains("composer-2.5-fast"))
        XCTAssertTrue(provisioner.status(for: .vscode, settings: settings).installed)
    }

    func testStatusesRequireCurrentLocalBaseURL() throws {
        let home = try temporaryHome()
        let provisioner = AgentProvisioner(homeDirectory: home)
        let original = CursorAPISettings(port: 8787)
        let moved = CursorAPISettings(port: 9999)

        try provisioner.install(.opencode, settings: original)
        try provisioner.install(.codex, settings: original)
        try provisioner.install(.vscode, settings: original)

        let opencode = provisioner.status(for: .opencode, settings: moved)
        let codex = provisioner.status(for: .codex, settings: moved)
        let vscode = provisioner.status(for: .vscode, settings: moved)

        XCTAssertFalse(opencode.installed)
        XCTAssertFalse(codex.installed)
        XCTAssertFalse(vscode.installed)
        XCTAssertTrue(opencode.canInstall)
        XCTAssertTrue(codex.canInstall)
        XCTAssertTrue(vscode.canInstall)
        XCTAssertTrue(opencode.detail.contains("different local URL"))
        XCTAssertTrue(codex.detail.contains("different local URL"))
        XCTAssertTrue(vscode.detail.contains("different local URL"))
    }

    private func temporaryHome() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "CursorAPITests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func countOccurrences(of needle: String, in text: String) -> Int {
        text.components(separatedBy: needle).count - 1
    }
}
