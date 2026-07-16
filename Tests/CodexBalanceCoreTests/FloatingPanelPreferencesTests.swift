import Testing
@testable import CodexBalanceCore

@Suite
struct FloatingPanelPreferencesTests {
  @Test
  func defaultSelectionCoversEveryFloatingPanelInformationModule() {
    #expect(FloatingPanelMetric.defaults == Set(FloatingPanelMetric.allCases))
    #expect(FloatingPanelMetric.defaults.count == 4)
    #expect(FloatingPanelMetric.allCases.allSatisfy {
      !$0.title.isEmpty && !$0.subtitle.isEmpty && !$0.systemImage.isEmpty
    })
  }

  @Test
  func savedSelectionWinsAndUnknownValuesAreIgnored() {
    let selection = FloatingPanelMetric.resolvedSelection(
      rawValues: ["rolling24Tokens", "resetRadar", "futureMetric"],
      legacyShowsResetCredits: false
    )

    #expect(selection == [.rolling24Tokens, .resetRadar])
  }

  @Test
  func legacyResetPreferenceMigratesWithoutHidingOtherInformation() {
    let selection = FloatingPanelMetric.resolvedSelection(
      rawValues: nil,
      legacyShowsResetCredits: false
    )

    #expect(!selection.contains(.resetCredits))
    #expect(selection.contains(.weeklyQuota))
    #expect(selection.contains(.rolling24Tokens))
    #expect(selection.contains(.resetRadar))
  }

  @Test
  func emptySelectionPersistsAsSafeDefaults() {
    let rawValues = FloatingPanelMetric.persistedRawValues([])

    #expect(Set(rawValues) == Set(FloatingPanelMetric.allCases.map(\.rawValue)))
    #expect(rawValues == rawValues.sorted())
  }

  @Test(arguments: [true, false])
  func manualLaunchAlwaysShowsAWindow(floatingPanelEnabled: Bool) {
    #expect(FloatingPanelStartupPolicy.shouldShowWindow(
      floatingPanelEnabled: floatingPanelEnabled,
      launchedInBackground: false
    ))
  }

  @Test
  func backgroundLaunchStaysHiddenWhenFloatingPanelIsDisabled() {
    #expect(!FloatingPanelStartupPolicy.shouldShowWindow(
      floatingPanelEnabled: false,
      launchedInBackground: true
    ))
    #expect(FloatingPanelStartupPolicy.shouldShowWindow(
      floatingPanelEnabled: true,
      launchedInBackground: true
    ))
  }
}
