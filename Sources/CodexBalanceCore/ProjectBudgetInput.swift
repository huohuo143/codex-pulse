import Foundation

public enum ProjectBudgetInputError: Error, LocalizedError, Equatable, Sendable {
  case empty
  case invalidFormat
  case nonPositive
  case tooLarge

  public var errorDescription: String? {
    switch self {
    case .empty: "请输入每月 Token 上限"
    case .invalidFormat: "请输入正整数，或使用英文逗号分隔千位，例如 2,000,000"
    case .nonPositive: "预算必须大于 0 Token"
    case .tooLarge: "输入的 Token 上限过大，请减小数值"
    }
  }
}

public enum ProjectBudgetInput {
  public static func parse(_ text: String) -> Result<Int, ProjectBudgetInputError> {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return .failure(.empty) }

    // Only remove separators after checking the whole input. Dropping arbitrary
    // characters would silently turn decimals, negative values or exponents into a different budget.
    let groups = trimmed.split(separator: ",", omittingEmptySubsequences: false)
    guard groups.allSatisfy({ !$0.isEmpty && $0.utf8.allSatisfy { (48...57).contains($0) } }),
      groups.count == 1 || ((1...3).contains(groups[0].count) && groups.dropFirst().allSatisfy { $0.count == 3 })
    else { return .failure(.invalidFormat) }

    guard let value = Int(groups.joined()) else { return .failure(.tooLarge) }
    guard value > 0 else { return .failure(.nonPositive) }
    return .success(value)
  }
}
