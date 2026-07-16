import Testing
@testable import CodexBalanceCore

@Suite
struct DashboardThemeModeTests {
  @Test
  func offersSystemDayAndNightModes() {
    #expect(DashboardThemeMode.allCases == [.system, .day, .night])
    #expect(DashboardThemeMode.defaultMode == .system)
  }

  @Test(arguments: DashboardThemeMode.allCases)
  func persistedValuesRoundTrip(mode: DashboardThemeMode) {
    #expect(DashboardThemeMode(rawValue: mode.rawValue) == mode)
    #expect(!mode.title.isEmpty)
    #expect(!mode.subtitle.isEmpty)
    #expect(!mode.systemImage.isEmpty)
  }
}
