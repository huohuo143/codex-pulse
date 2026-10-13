import Foundation

/// Notification receipts belong to the anonymous local account scope that produced them.
/// The legacy unscoped `quotaAlertLedger` key is deliberately preserved, never adopted:
/// it contains no evidence identifying the account to which its receipts belong.
public final class QuotaAlertLedgerStore {
  private static let keyPrefix = "quotaAlertLedger.account.v1."
  private let defaults: UserDefaults

  public init(defaults: UserDefaults = PulsePreferences.shared) {
    self.defaults = defaults
  }

  public func load(account: String?) -> QuotaAlertLedger {
    guard let key = storageKey(account: account), let data = defaults.data(forKey: key),
      let ledger = try? JSONDecoder().decode(QuotaAlertLedger.self, from: data) else {
      return QuotaAlertLedger()
    }
    return ledger
  }

  public func save(_ ledger: QuotaAlertLedger, account: String?) {
    guard let key = storageKey(account: account), let data = try? JSONEncoder().encode(ledger) else { return }
    defaults.set(data, forKey: key)
  }

  private func storageKey(account: String?) -> String? {
    guard let account, !account.isEmpty else { return nil }
    return Self.keyPrefix + account
  }
}
