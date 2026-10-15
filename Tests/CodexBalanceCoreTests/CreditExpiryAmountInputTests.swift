import Foundation
import Testing
@testable import CodexBalanceCore

@Suite("Credit grant quantity validation")
struct CreditExpiryAmountInputTests {
  @Test func blankIsUnknownAndValidQuantitiesKeepTheirValue() throws {
    #expect(try CreditExpiryAmountInput.parse(" \n ") == nil)
    for (text, expected) in [("62,500", 62500.0), ("62500.5", 62500.5), ("1,234,567.89", 1234567.89), (" 0.125 ", 0.125)] {
      #expect(try CreditExpiryAmountInput.parse(text) == expected)
    }
  }

  @Test func malformedSeparatorsCannotChangeTheAmount() {
    for text in ["1,5", "2,00", "12,3456", "1,,000", ",100", "100,", "1.000,25", "-1", "0", "NaN", "inf", "1e309", "1e-999", "1 000", "１,０００", "12 credits"] {
      #expect(throws: CreditExpiryAmountInput.ValidationError.self) { try CreditExpiryAmountInput.parse(text) }
    }
  }

  @Test func storedQuantityRoundTripsWithoutSixDigitRounding() throws {
    for quantity in [62500.123456789, 123456789.125, 0.000000123456789, 1e25] {
      #expect(try CreditExpiryAmountInput.parse(String(quantity)) == quantity)
    }
  }
}
