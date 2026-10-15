import Foundation

public enum CreditExpiryAmountInput {
  public enum ValidationError: Error, LocalizedError {
    case invalid

    public var errorDescription: String? {
      "发放数量须为正数，可留空；英文逗号仅用于千位分组，例如 62,500 或 62500.5"
    }
  }

  public static func parse(_ text: String) throws -> Double? {
    let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty else { return nil }
    // Validate grouping before removing commas. Scientific notation also allows
    // the lossless String(Double) representation of existing small/large values.
    let pattern = #"^(?:[0-9]+|[0-9]{1,3}(?:,[0-9]{3})+)(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#
    guard value.range(of: pattern, options: .regularExpression) != nil,
      let amount = Double(value.replacingOccurrences(of: ",", with: "")),
      amount.isFinite, amount > 0 else { throw ValidationError.invalid }
    return amount
  }
}
