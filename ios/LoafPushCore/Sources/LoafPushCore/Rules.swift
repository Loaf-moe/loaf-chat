import Foundation

/// `rules.json` as the app wrote it, kept whole: the evaluator is handed the
/// same document the app hands it, user id and display name included.
public struct Rules {
  public let json: Data
  public let writtenAt: Date?

  public init(json: Data, writtenAt: Date?) {
    self.json = json
    self.writtenAt = writtenAt
  }
}

/// How long a written ruleset is taken to still describe the account.
public let rulesFreshFor: TimeInterval = 3600

/// Nil for a file that is missing, unreadable, or holds no ruleset. The
/// caller must tell those from an empty ruleset: an empty one silences
/// every push, and this is the one thing the extension fails open on.
public func loadRules(_ url: URL) -> Rules? {
  guard let data = try? Data(contentsOf: url),
    let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
    object["rules"] != nil
  else { return nil }
  let writtenAt = (object["written_at"] as? NSNumber).map {
    Date(timeIntervalSince1970: $0.doubleValue / 1000)
  }
  return Rules(json: data, writtenAt: writtenAt)
}

/// No rules, or rules whose age we cannot tell, count as stale too: the
/// caller is asking whether it may lean on them, and the honest answer
/// when we do not know is no.
public func isStale(_ rules: Rules?, now: Date) -> Bool {
  guard let rules, let writtenAt = rules.writtenAt else { return true }
  return now.timeIntervalSince(writtenAt) > rulesFreshFor
}
