import Foundation

/// One room, as `names.json` describes it: where the app would say it is,
/// whether it is a DM, and the joined-member count the push rules judge
/// `room_member_count` against.
public struct RoomName: Decodable {
  public let place: String?
  public let dm: Bool
  public let members: Int?

  public init(place: String?, dm: Bool, members: Int?) {
    self.place = place
    self.dm = dm
    self.members = members
  }

  private enum CodingKeys: String, CodingKey { case place, dm, members }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    place = try? values.decode(String.self, forKey: .place)
    dm = (try? values.decode(Bool.self, forKey: .dm)) ?? false
    members = try? values.decode(Int.self, forKey: .members)
  }
}

/// Missing or unreadable gives no names at all, which costs a title, not a
/// notification.
public func loadNames(_ url: URL) -> [String: RoomName] {
  guard let data = try? Data(contentsOf: url),
    let names = try? JSONDecoder().decode([String: RoomName].self, from: data)
  else { return [:] }
  return names
}

/// `notifications.json`, written by the app. Every answer defaults to yes,
/// so a missing or half-written file never silences anything.
public struct DeviceSettings: Decodable {
  public var notifications = true
  public var sound = true
  public var showText = true

  public init() {}

  private enum CodingKeys: String, CodingKey { case notifications, sound, showText }

  public init(from decoder: Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    notifications = (try? values.decode(Bool.self, forKey: .notifications)) ?? true
    sound = (try? values.decode(Bool.self, forKey: .sound)) ?? true
    showText = (try? values.decode(Bool.self, forKey: .showText)) ?? true
  }
}

public func loadSettings(_ url: URL) -> DeviceSettings {
  guard let data = try? Data(contentsOf: url),
    let settings = try? JSONDecoder().decode(DeviceSettings.self, from: data)
  else { return DeviceSettings() }
  return settings
}
