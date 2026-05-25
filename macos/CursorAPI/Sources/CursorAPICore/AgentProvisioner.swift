import Foundation

public final class AgentProvisioner: @unchecked Sendable {
    private let homeDirectory: URL
    private let fileManager: FileManager

    public init(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser, fileManager: FileManager = .default) {
        self.homeDirectory = homeDirectory
        self.fileManager = fileManager
    }

    public func statuses(settings: CursorAPISettings) -> [AgentIntegrationStatus] {
        AgentIntegrationID.allCases.map { status(for: $0, settings: settings) }
    }

    public func status(for id: AgentIntegrationID, settings: CursorAPISettings) -> AgentIntegrationStatus {
        switch id {
        case .opencode:
            return opencodeStatus(settings: settings)
        case .codex:
            return codexStatus(settings: settings)
        case .vscode:
            return vscodeStatus(settings: settings)
        case .cline:
            return extensionStatus(id: .cline, settings: settings)
        case .kilo:
            return extensionStatus(id: .kilo, settings: settings)
        case .pi:
            return piStatus(settings: settings)
        }
    }

    public func install(_ id: AgentIntegrationID, settings: CursorAPISettings) throws {
        switch id {
        case .opencode:
            try installOpenCode(settings: settings)
        case .codex:
            try installCodex(settings: settings)
        case .vscode:
            try installVSCode(settings: settings)
        case .cline:
            try installCline(settings: settings)
        case .kilo:
            try installKilo(settings: settings)
        case .pi:
            try installPi(settings: settings)
        }
    }

    private func opencodeStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = opencodeConfigURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .opencode, installed: false, configPath: url.path, detail: "OpenCode config not found")
        }
        let text = fileText(url)
        let installed = text.contains(settings.baseURL.absoluteString)
        let detail = installed ? "Composer models installed" : text.contains("cursorapi") ? "Provider found with a different local URL" : "Ready to install"
        return AgentIntegrationStatus(id: .opencode, installed: installed, configPath: url.path, detail: detail)
    }

    private func installOpenCode(settings: CursorAPISettings) throws {
        let url = opencodeConfigURL()
        var root = try readJSONObject(url, defaultValue: [:])
        var provider = root["provider"] as? [String: Any] ?? [:]
        provider["cursorapi"] = [
            "npm": "@ai-sdk/openai-compatible",
            "name": "CursorAPI",
            "options": [
                "baseURL": settings.baseURL.absoluteString,
                "apiKey": "cursor-local"
            ],
            "models": [
                "composer-2.5": [
                    "name": "Composer 2.5"
                ],
                "composer-2.5-fast": [
                    "name": "Composer 2.5 Fast"
                ]
            ]
        ]
        root["provider"] = provider
        if root["model"] == nil {
            root["model"] = "cursorapi/composer-2.5"
        }
        try writeJSONObject(root, to: url)
    }

    private func codexStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = codexConfigURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .codex, installed: false, configPath: url.path, detail: "Codex config not found")
        }
        let text = fileText(url)
        let installed = text.contains(settings.baseURL.absoluteString)
        let detail = installed ? "Custom provider installed" : text.contains("[model_providers.cursorapi]") ? "Provider found with a different local URL" : "Ready to install"
        return AgentIntegrationStatus(id: .codex, installed: installed, configPath: url.path, detail: detail)
    }

    private func installCodex(settings: CursorAPISettings) throws {
        let url = codexConfigURL()
        try ensureParentDirectory(url)
        var text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        let block = """

        [model_providers.cursorapi]
        name = "CursorAPI"
        base_url = "\(settings.baseURL.absoluteString)"
        env_key = "CURSOR_API_KEY"
        wire_api = "responses"

        [profiles.cursorapi]
        model_provider = "cursorapi"
        model = "composer-2.5"

        [profiles.cursorapi-fast]
        model_provider = "cursorapi"
        model = "composer-2.5-fast"
        """
        text = replaceTOMLBlock(named: "model_providers.cursorapi", in: text, replacement: "")
        text = replaceTOMLBlock(named: "profiles.cursorapi", in: text, replacement: "")
        text = replaceTOMLBlock(named: "profiles.cursorapi-fast", in: text, replacement: "")
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !text.isEmpty {
            text += "\n"
        }
        text += block.trimmingCharacters(in: .whitespacesAndNewlines)
        text += "\n"
        try writeText(text, to: url)
    }

    private func vscodeStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = vscodeLanguageModelsURL()
        guard fileManager.fileExists(atPath: url.path) else {
            return AgentIntegrationStatus(id: .vscode, installed: false, configPath: url.path, detail: "VS Code chatLanguageModels.json not found")
        }
        let text = fileText(url)
        let installed = text.contains(settings.baseURL.absoluteString)
        let detail = installed ? "Model metadata installed" : text.contains("CursorAPI") ? "Model metadata found with a different local URL" : "Ready to install"
        return AgentIntegrationStatus(id: .vscode, installed: installed, configPath: url.path, detail: detail)
    }

    private func installVSCode(settings: CursorAPISettings) throws {
        let url = vscodeLanguageModelsURL()
        var array = try readJSONArray(url, defaultValue: [])
        array.removeAll { item in
            guard let record = item as? [String: Any] else { return false }
            return record["name"] as? String == "CursorAPI"
        }
        array.append([
            "name": "CursorAPI",
            "provider": "openai-compatible",
            "baseUrl": settings.baseURL.absoluteString,
            "models": ["composer-2.5", "composer-2.5-fast"]
        ])
        try writeJSONValue(array, to: url)
    }

    private func extensionStatus(id: AgentIntegrationID, settings: CursorAPISettings) -> AgentIntegrationStatus {
        if id == .cline {
            let url = clineGlobalStateURL()
            let installed = fileManager.fileExists(atPath: url.path) && jsonFileContains(url, needle: settings.baseURL.absoluteString)
            return AgentIntegrationStatus(id: id, installed: installed, configPath: url.path, detail: installed ? "Provider profile installed" : "Ready to install")
        }
        if id == .kilo {
            let url = kiloConfigURL()
            let installed = fileManager.fileExists(atPath: url.path) && jsonFileContains(url, needle: settings.baseURL.absoluteString)
            return AgentIntegrationStatus(id: id, installed: installed, configPath: url.path, detail: installed ? "Provider profile installed" : "Ready to install")
        }
        let roots = vscodeExtensionStateRoots(for: id)
        let existing = roots.first { fileManager.fileExists(atPath: $0.path) }
        guard let existing else {
            return AgentIntegrationStatus(id: id, installed: false, configPath: nil, detail: "Extension state not found", canInstall: false)
        }
        let installed = directoryContains(existing, needle: settings.baseURL.absoluteString)
        return AgentIntegrationStatus(id: id, installed: installed, configPath: existing.path, detail: installed ? "Local provider detected" : "Detected; configure through extension UI", canInstall: false)
    }

    private func piStatus(settings: CursorAPISettings) -> AgentIntegrationStatus {
        let url = piModelsURL()
        let exists = fileManager.fileExists(atPath: url.path)
        let installed = exists && jsonFileContains(url, needle: settings.baseURL.absoluteString)
        return AgentIntegrationStatus(id: .pi, installed: installed, configPath: url.path, detail: installed ? "Custom models installed" : "Ready to install")
    }

    private func installCline(settings: CursorAPISettings) throws {
        let globalStateURL = clineGlobalStateURL()
        var globalState = try readJSONObject(globalStateURL, defaultValue: [:])
        globalState["actModeApiProvider"] = "openai"
        globalState["planModeApiProvider"] = "openai"
        globalState["actModeOpenAiModelId"] = "composer-2.5"
        globalState["planModeOpenAiModelId"] = "composer-2.5"
        globalState["openAiBaseUrl"] = settings.baseURL.absoluteString
        globalState["welcomeViewCompleted"] = true
        if globalState["remoteRulesToggles"] == nil {
            globalState["remoteRulesToggles"] = [:]
        }
        if globalState["remoteWorkflowToggles"] == nil {
            globalState["remoteWorkflowToggles"] = [:]
        }
        try writeJSONObject(globalState, to: globalStateURL)

        let secretsURL = clineSecretsURL()
        var secrets = try readJSONObject(secretsURL, defaultValue: [:])
        secrets["openAiApiKey"] = "cursor-local"
        try writeJSONObject(secrets, to: secretsURL)
    }

    private func installKilo(settings: CursorAPISettings) throws {
        let url = kiloConfigURL()
        var root = try readJSONObject(url, defaultValue: ["$schema": "https://app.kilo.ai/config.json"])
        var provider = root["provider"] as? [String: Any] ?? [:]
        provider["cursorapi"] = [
            "options": [
                "baseURL": settings.baseURL.absoluteString,
                "apiKey": "cursor-local"
            ],
            "models": [
                "composer-2.5": [
                    "name": "Composer 2.5",
                    "limit": [
                        "context": 128_000,
                        "output": 16_384
                    ]
                ],
                "composer-2.5-fast": [
                    "name": "Composer 2.5 Fast",
                    "limit": [
                        "context": 128_000,
                        "output": 16_384
                    ]
                ]
            ]
        ]
        root["provider"] = provider
        if root["model"] == nil {
            root["model"] = "cursorapi/composer-2.5"
        }
        try writeJSONObject(root, to: url)
    }

    private func installPi(settings: CursorAPISettings) throws {
        let url = piModelsURL()
        var root = try readJSONObject(url, defaultValue: ["providers": [:]])
        var providers = root["providers"] as? [String: Any] ?? [:]
        providers["cursorapi"] = [
            "baseUrl": settings.baseURL.absoluteString,
            "apiKey": "cursor-local",
            "authHeader": true,
            "api": "openai-completions",
            "models": piModelDefinitions()
        ]
        root["providers"] = providers
        try writeJSONObject(root, to: url)
    }

    private func opencodeConfigURL() -> URL {
        homeDirectory.appending(path: ".config/opencode/opencode.json")
    }

    private func codexConfigURL() -> URL {
        homeDirectory.appending(path: ".codex/config.toml")
    }

    private func vscodeLanguageModelsURL() -> URL {
        homeDirectory.appending(path: "Library/Application Support/Code/User/chatLanguageModels.json")
    }

    private func clineGlobalStateURL() -> URL {
        homeDirectory.appending(path: ".cline/data/globalState.json")
    }

    private func clineSecretsURL() -> URL {
        homeDirectory.appending(path: ".cline/data/secrets.json")
    }

    private func kiloConfigURL() -> URL {
        homeDirectory.appending(path: ".config/kilo/kilo.jsonc")
    }

    private func piModelsURL() -> URL {
        homeDirectory.appending(path: ".pi/agent/models.json")
    }

    private func piModelDefinitions() -> [[String: Any]] {
        [
            [
                "id": "composer-2.5",
                "name": "Composer 2.5",
                "api": "openai-completions",
                "reasoning": false,
                "input": ["text"],
                "contextWindow": 128_000,
                "maxTokens": 16_384,
                "cost": ["input": 0.5, "output": 2.5, "cacheRead": 0, "cacheWrite": 0],
                "compat": [
                    "supportsUsageInStreaming": true,
                    "maxTokensField": "max_tokens",
                    "requiresAssistantAfterToolResult": false
                ]
            ],
            [
                "id": "composer-2.5-fast",
                "name": "Composer 2.5 Fast",
                "api": "openai-completions",
                "reasoning": false,
                "input": ["text"],
                "contextWindow": 128_000,
                "maxTokens": 16_384,
                "cost": ["input": 3.0, "output": 15.0, "cacheRead": 0, "cacheWrite": 0],
                "compat": [
                    "supportsUsageInStreaming": true,
                    "maxTokensField": "max_tokens",
                    "requiresAssistantAfterToolResult": false
                ]
            ]
        ]
    }

    private func vscodeExtensionStateRoots(for id: AgentIntegrationID) -> [URL] {
        let base = homeDirectory.appending(path: "Library/Application Support/Code/User/globalStorage")
        switch id {
        case .cline:
            return [
                base.appending(path: "saoudrizwan.claude-dev"),
                base.appending(path: "cline.cline")
            ]
        case .kilo:
            return [
                base.appending(path: "kilocode.kilo-code"),
                base.appending(path: "kilocode.kilo")
            ]
        default:
            return []
        }
    }

    private func readJSONObject(_ url: URL, defaultValue: [String: Any]) throws -> [String: Any] {
        guard fileManager.fileExists(atPath: url.path) else { return defaultValue }
        let value = try readJSONValue(url)
        guard let object = value as? [String: Any] else {
            throw CursorAPIError.badRequest("\(url.lastPathComponent) must contain a JSON object.")
        }
        return object
    }

    private func readJSONArray(_ url: URL, defaultValue: [Any]) throws -> [Any] {
        guard fileManager.fileExists(atPath: url.path) else { return defaultValue }
        let value = try readJSONValue(url)
        guard let array = value as? [Any] else {
            throw CursorAPIError.badRequest("\(url.lastPathComponent) must contain a JSON array.")
        }
        return array
    }

    private func readJSONValue(_ url: URL) throws -> Any {
        let data = try Data(contentsOf: url)
        let raw = String(data: data, encoding: .utf8) ?? ""
        let parseData = Data(stripJSONComments(raw).utf8)
        do {
            return try JSONSerialization.jsonObject(with: parseData)
        } catch {
            throw CursorAPIError.badRequest("Could not parse \(url.lastPathComponent): \(error.localizedDescription)")
        }
    }

    private func writeJSONObject(_ object: [String: Any], to url: URL) throws {
        try writeJSONValue(object, to: url)
    }

    private func writeJSONValue(_ value: Any, to url: URL) throws {
        try ensureParentDirectory(url)
        let data = try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        try backupIfChanged(url, replacementData: data)
        try data.write(to: url, options: .atomic)
    }

    private func writeText(_ text: String, to url: URL) throws {
        try ensureParentDirectory(url)
        let data = Data(text.utf8)
        try backupIfChanged(url, replacementData: data)
        try data.write(to: url, options: .atomic)
    }

    private func ensureParentDirectory(_ url: URL) throws {
        let parent = url.deletingLastPathComponent()
        try fileManager.createDirectory(at: parent, withIntermediateDirectories: true)
    }

    private func jsonFileContains(_ url: URL, needle: String) -> Bool {
        guard fileManager.fileExists(atPath: url.path), !needle.isEmpty else { return false }
        return fileText(url).contains(needle)
    }

    private func fileText(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    private func backupIfChanged(_ url: URL, replacementData: Data) throws {
        guard fileManager.fileExists(atPath: url.path) else { return }
        let current = try Data(contentsOf: url)
        guard current != replacementData else { return }
        let backupURL = backupURL(for: url)
        try fileManager.copyItem(at: url, to: backupURL)
    }

    private func backupURL(for url: URL) -> URL {
        let stamp = String(Int(Date().timeIntervalSince1970 * 1000))
        let parent = url.deletingLastPathComponent()
        let baseName = "\(url.lastPathComponent).cursorapi-backup.\(stamp)"
        var candidate = parent.appending(path: baseName)
        var index = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appending(path: "\(baseName).\(index)")
            index += 1
        }
        return candidate
    }

    private func directoryContains(_ url: URL, needle: String) -> Bool {
        guard let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: nil), !needle.isEmpty else { return false }
        for case let fileURL as URL in enumerator where fileURL.pathExtension == "json" {
            if jsonFileContains(fileURL, needle: needle) {
                return true
            }
        }
        return false
    }

    private func replaceTOMLBlock(named name: String, in text: String, replacement: String) -> String {
        let section = NSRegularExpression.escapedPattern(for: "[\(name)]")
        let pattern = #"(?ms)^"# + section + #"\n.*?(?=^\[|\z)"#
        return text.replacingOccurrences(of: pattern, with: replacement.isEmpty ? "" : replacement + "\n", options: .regularExpression)
    }

    private func stripJSONComments(_ text: String) -> String {
        var output = ""
        var index = text.startIndex
        var inString = false
        var isEscaped = false
        while index < text.endIndex {
            let character = text[index]
            let nextIndex = text.index(after: index)
            let next = nextIndex < text.endIndex ? text[nextIndex] : nil

            if inString {
                output.append(character)
                if isEscaped {
                    isEscaped = false
                } else if character == "\\" {
                    isEscaped = true
                } else if character == "\"" {
                    inString = false
                }
                index = nextIndex
                continue
            }

            if character == "\"" {
                inString = true
                output.append(character)
                index = nextIndex
                continue
            }

            if character == "/", next == "/" {
                index = text.index(after: nextIndex)
                while index < text.endIndex, text[index] != "\n" {
                    index = text.index(after: index)
                }
                if index < text.endIndex {
                    output.append("\n")
                    index = text.index(after: index)
                }
                continue
            }

            if character == "/", next == "*" {
                index = text.index(after: nextIndex)
                while index < text.endIndex {
                    let closeNext = text.index(after: index)
                    if text[index] == "*", closeNext < text.endIndex, text[closeNext] == "/" {
                        index = text.index(after: closeNext)
                        break
                    }
                    if text[index] == "\n" {
                        output.append("\n")
                    }
                    index = text.index(after: index)
                }
                continue
            }

            output.append(character)
            index = nextIndex
        }
        return output
    }
}
