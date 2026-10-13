import Testing
@testable import CodexBalanceCore

@Suite("Project budget input")
struct ProjectBudgetInputTests {
  @Test(arguments: ["2000000", "2,000,000", " 2,000,000\n", "1", "001"])
  func acceptsPositiveIntegersAndCompleteThousandsGroups(_ input: String) throws {
    let expected = input.contains("2") ? 2_000_000 : 1
    #expect(try ProjectBudgetInput.parse(input).get() == expected)
  }

  @Test(arguments: ["-100", "+100", "1.5", "1e6", "100 Token", "2 000", "2,00", "2000,000", ",100", "100,", "1,,000", "１,０００"])
  func rejectsInputThatWouldOtherwiseChangeItsMeaning(_ input: String) {
    #expect(ProjectBudgetInput.parse(input) == .failure(.invalidFormat))
  }

  @Test func rejectsEmptyZeroAndOverflow() throws {
    #expect(ProjectBudgetInput.parse(" \n") == .failure(.empty))
    #expect(ProjectBudgetInput.parse("0") == .failure(.nonPositive))
    #expect(ProjectBudgetInput.parse("0,000") == .failure(.nonPositive))
    #expect(ProjectBudgetInput.parse(String(Int.max) + "0") == .failure(.tooLarge))
    #expect(try ProjectBudgetInput.parse(String(Int.max)).get() == Int.max)
  }
}
