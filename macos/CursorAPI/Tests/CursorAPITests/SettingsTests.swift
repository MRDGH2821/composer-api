import CursorAPICore
import XCTest

final class SettingsTests: XCTestCase {
    func testSettingsDecodeOldPersistedShapeWithoutKeychainMarker() throws {
        let data = Data("""
        {
          "port": 9999,
          "cursorAPIBaseURL": "https://api.cursor.com",
          "backendBaseURL": "",
          "localAgentEndpoint": "",
          "clientVersion": "sdk-1.0.13",
          "launchAtLogin": false
        }
        """.utf8)

        let settings = try JSONDecoder().decode(CursorAPISettings.self, from: data)

        XCTAssertEqual(settings.port, 9999)
        XCTAssertFalse(settings.hasCursorAPIKey)
        XCTAssertFalse(settings.keychainCursorAPIKeyAvailable)
    }

    func testKeychainAvailabilityCountsAsSavedAPIKeyWithoutSecretInMemory() {
        let settings = CursorAPISettings(cursorAPIKey: "", keychainCursorAPIKeyAvailable: true)

        XCTAssertTrue(settings.hasCursorAPIKey)
        XCTAssertFalse(settings.hasInlineCursorAPIKey)
    }

    func testSettingsEncodingDoesNotPersistKeychainAvailabilityMarker() throws {
        var settings = CursorAPISettings(keychainCursorAPIKeyAvailable: true)
        settings.cursorAPIKey = ""

        let data = try JSONEncoder.cursorAPIPretty.encode(settings)
        let text = String(decoding: data, as: UTF8.self)

        XCTAssertFalse(text.contains("keychainCursorAPIKeyAvailable"))
    }

    func testBundledTransportDefaultsFillMissingSDKSettings() {
        let defaults = isolatedDefaults()
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [:],
            bundledTransportDefaults: {
                [
                    "backendBaseURL": "https://bundled.example",
                    "localAgentEndpoint": "/sdk/run",
                    "clientVersion": "sdk-test"
                ]
            }
        )

        let settings = store.load()

        XCTAssertEqual(settings.backendBaseURL, "https://bundled.example")
        XCTAssertEqual(settings.localAgentEndpoint, "/sdk/run")
        XCTAssertEqual(settings.clientVersion, "sdk-test")
    }

    func testEnvironmentOverridesBundledTransportDefaults() {
        let defaults = isolatedDefaults()
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [
                "CURSOR_BACKEND_BASE_URL": "https://env.example",
                "CURSOR_LOCAL_AGENT_ENDPOINT": "/env/run",
                "CURSOR_SDK_CLIENT_VERSION": "sdk-env"
            ],
            bundledTransportDefaults: {
                [
                    "backendBaseURL": "https://bundled.example",
                    "localAgentEndpoint": "/sdk/run",
                    "clientVersion": "sdk-test"
                ]
            }
        )

        let settings = store.load()

        XCTAssertEqual(settings.backendBaseURL, "https://env.example")
        XCTAssertEqual(settings.localAgentEndpoint, "/env/run")
        XCTAssertEqual(settings.clientVersion, "sdk-env")
    }

    func testSavedTransportSettingsOverrideBundledDefaults() throws {
        let defaults = isolatedDefaults()
        let saved = CursorAPISettings(
            port: 8787,
            cursorAPIKey: "",
            cursorAPIBaseURL: "https://api.cursor.com",
            backendBaseURL: "https://saved.example",
            localAgentEndpoint: "/saved/run",
            clientVersion: "sdk-saved",
            launchAtLogin: false
        )
        let data = try JSONEncoder.cursorAPIPretty.encode(saved)
        defaults.set(data, forKey: "CursorAPI.settings.v1")
        let store = AppSettingsStore(
            defaults: defaults,
            environment: [:],
            bundledTransportDefaults: {
                [
                    "backendBaseURL": "https://bundled.example",
                    "localAgentEndpoint": "/sdk/run",
                    "clientVersion": "sdk-test"
                ]
            }
        )

        let settings = store.load()

        XCTAssertEqual(settings.backendBaseURL, "https://saved.example")
        XCTAssertEqual(settings.localAgentEndpoint, "/saved/run")
        XCTAssertEqual(settings.clientVersion, "sdk-saved")
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "CursorAPI.SettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
