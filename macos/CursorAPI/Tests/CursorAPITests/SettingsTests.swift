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
}
