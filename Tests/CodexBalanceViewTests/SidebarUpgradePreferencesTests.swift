import Foundation
import SidebarCore
import Testing
@testable import CodexBalance

@Suite("Sidebar preferences across upgrades", .serialized)
struct SidebarUpgradePreferencesTests {
  @Test @MainActor func preservesDisabledChoicesAcrossModelRestarts() throws {
    let suite = "SidebarUpgradePreferencesTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let selected = SidebarVisibility(quota: false, radar: true, credits: false, reset: false, apiUsage: false)
    selected.save(to: defaults)
    defaults.set(false, forKey: "sidebarStatusEnabled")
    let first = SidebarModel(defaults: defaults)
    #expect(first.visibility == selected)
    #expect(!first.enabled)
    let afterUpdate = SidebarModel(defaults: defaults)
    #expect(afterUpdate.visibility == selected)
    #expect(!afterUpdate.enabled)
  }
}
