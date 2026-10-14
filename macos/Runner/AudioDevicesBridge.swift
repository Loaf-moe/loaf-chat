import CoreAudio
import FlutterMacOS
import WebRTC
import flutter_webrtc

/// Lists the Mac's microphones and speakers over `loaf/audio`, says when
/// they change, and points WebRTC's playback at one of them. An id is the
/// device's CoreAudio UID, which is what WebRTC knows it by too.
///
/// WebRTC's own list will not do: it has only the default until a call
/// starts, and during one it counts the echo canceller's tap on each
/// speaker as a microphone.
final class AudioDevicesBridge: NSObject {
  private static let system = AudioObjectID(kAudioObjectSystemObject)

  /// Everything here is asked off the main thread, where Dart runs too.
  /// CoreAudio answers slowly while a device is changing. A speaker is
  /// chosen on the plugin's own queue: WebRTC rebuilds its audio engine
  /// before it answers, which takes seconds, and the plugin's calls from
  /// Dart wait their turn behind it instead of meeting it halfway.
  private static let work = DispatchQueue(label: "loaf.audio")

  /// What an output stream plays through. The echo canceller's tap on a
  /// speaker is an input stream that still says one of these.
  private static let outputTerminals: Set<UInt32> = [
    kAudioStreamTerminalTypeSpeaker,
    kAudioStreamTerminalTypeHeadphones,
    kAudioStreamTerminalTypeLFESpeaker,
    kAudioStreamTerminalTypeReceiverSpeaker,
    kAudioStreamTerminalTypeHDMI,
    kAudioStreamTerminalTypeDisplayPort,
  ]

  private let channel: FlutterMethodChannel

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "loaf/audio", binaryMessenger: messenger)
    super.init()
    channel.setMethodCallHandler { call, result in
      let answer: () -> Any?
      var queue = Self.work
      switch call.method {
      case "microphones":
        answer = { Self.listed(Self.isMicrophone) }
      case "speakers":
        answer = { Self.listed(Self.isSpeaker) }
      case "selectSpeaker":
        let id = call.arguments as? String
        answer = { Self.selectSpeaker(id) }
        queue = FlutterWebRTCWorkQueue()
      default:
        result(FlutterMethodNotImplemented)
        return
      }
      queue.async {
        let answered = answer()
        DispatchQueue.main.async { result(answered) }
      }
    }
    var devices = Self.address(kAudioHardwarePropertyDevices)
    AudioObjectAddPropertyListenerBlock(Self.system, &devices, .main) {
      [weak self] _, _ in
      self?.channel.invokeMethod("changed", arguments: nil)
    }
  }

  private static func listed(_ wanted: (AudioObjectID) -> Bool) -> [[String: String]] {
    devices().filter(wanted).compactMap { device in
      guard let id = uid(of: device), let label = name(of: device) else { return nil }
      return ["id": id, "label": label]
    }
  }

  private static func isMicrophone(_ device: AudioObjectID) -> Bool {
    !isAggregate(device) && !isDisplay(device)
      && streams(of: device, kAudioObjectPropertyScopeInput).contains { stream in
        !outputTerminals.contains(
          number(of: stream, kAudioStreamPropertyTerminalType)
            ?? kAudioStreamTerminalTypeUnknown)
      }
  }

  private static func isSpeaker(_ device: AudioObjectID) -> Bool {
    !isAggregate(device) && !isDisplay(device)
      && !streams(of: device, kAudioObjectPropertyScopeOutput).isEmpty
  }

  /// A call makes aggregates of its own.
  private static func isAggregate(_ device: AudioObjectID) -> Bool {
    number(of: device, kAudioDevicePropertyTransportType)
      == kAudioDeviceTransportTypeAggregate
  }

  /// A display's speakers. WebRTC leaves them out of its own list, and
  /// told to play through one it never finishes starting: every call into
  /// it after that waits for good, quitting among them.
  private static func isDisplay(_ device: AudioObjectID) -> Bool {
    [kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI]
      .contains(number(of: device, kAudioDevicePropertyTransportType))
  }

  /// Null when WebRTC has taken the device with `id`, else why not.
  private static func selectSpeaker(_ id: String?) -> FlutterError? {
    guard
      let module = FlutterWebRTCPlugin.sharedSingleton()?.peerConnectionFactory?
        .audioDeviceModule,
      let device = module.outputDevices.first(where: { $0.deviceId == id })
    else {
      return FlutterError(
        code: "selectSpeaker", message: "WebRTC has no such speaker", details: id)
    }
    module.outputDevice = device
    return nil
  }

  private static func devices() -> [AudioObjectID] {
    objects(of: system, address(kAudioHardwarePropertyDevices))
  }

  private static func streams(
    of device: AudioObjectID, _ scope: AudioObjectPropertyScope
  ) -> [AudioObjectID] {
    objects(of: device, address(kAudioDevicePropertyStreams, scope))
  }

  private static func objects(
    of object: AudioObjectID, _ property: AudioObjectPropertyAddress
  ) -> [AudioObjectID] {
    var property = property
    var size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(object, &property, 0, nil, &size) == noErr
    else { return [] }
    var ids = [AudioObjectID](
      repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &ids) == noErr
    else { return [] }
    return ids
  }

  private static func number(
    of object: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> UInt32? {
    var property = address(selector)
    var value: UInt32 = 0
    var size = UInt32(MemoryLayout<UInt32>.size)
    guard AudioObjectGetPropertyData(object, &property, 0, nil, &size, &value) == noErr
    else { return nil }
    return value
  }

  private static func uid(of device: AudioObjectID) -> String? {
    text(of: device, kAudioDevicePropertyDeviceUID)
  }

  private static func name(of device: AudioObjectID) -> String? {
    text(of: device, kAudioObjectPropertyName)
  }

  private static func text(
    of device: AudioObjectID, _ selector: AudioObjectPropertySelector
  ) -> String? {
    var property = address(selector)
    var value: Unmanaged<CFString>?
    var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
    guard AudioObjectGetPropertyData(device, &property, 0, nil, &size, &value) == noErr
    else { return nil }
    return value?.takeRetainedValue() as String?
  }

  private static func address(
    _ selector: AudioObjectPropertySelector,
    _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
  ) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(
      mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
  }
}
