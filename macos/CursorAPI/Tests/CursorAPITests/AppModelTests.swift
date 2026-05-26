import XCTest
@testable import CursorAPI
import CursorAPICore

final class AppModelTests: XCTestCase {
    func testInstallAllTitleUsesUnlockActionWhenSavedKeyIsLocked() {
        let statuses = [
            AgentIntegrationStatus(
                id: .opencode,
                installed: false,
                configPath: nil,
                detail: "Provider points at a hosted API"
            )
        ]

        XCTAssertEqual(
            CursorAPIAppModel.installAllIntegrationsTitle(
                for: statuses,
                isRunning: true,
                needsKeychainPermission: true
            ),
            "Unlock & Update All"
        )
    }

    func testInstallAllTitleUsesStartOnlyWhenServerIsStoppedAndKeyIsUnlocked() {
        let statuses = [
            AgentIntegrationStatus(
                id: .codex,
                installed: false,
                configPath: nil,
                detail: "Ready to install"
            )
        ]

        XCTAssertEqual(
            CursorAPIAppModel.installAllIntegrationsTitle(
                for: statuses,
                isRunning: false,
                needsKeychainPermission: false
            ),
            "Start & Install All"
        )
    }

    func testInstallAllTitleOmitsPrefixWhenServerIsReady() {
        let statuses = [
            AgentIntegrationStatus(
                id: .codex,
                installed: false,
                configPath: nil,
                detail: "Ready to install"
            )
        ]

        XCTAssertEqual(
            CursorAPIAppModel.installAllIntegrationsTitle(
                for: statuses,
                isRunning: true,
                needsKeychainPermission: false
            ),
            "Install All"
        )
    }
}
