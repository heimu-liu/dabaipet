import CoreAudio
import CoreMediaIO
import Foundation

// Query system activity only; this probe never starts a capture session.
struct QueryFailure: Error { let selector: UInt32; let status: OSStatus }

func audioValues(_ object: AudioObjectID, _ selector: UInt32, scope: UInt32 = kAudioObjectPropertyScopeGlobal) throws -> [UInt32] {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    var size: UInt32 = 0
    var status = AudioObjectGetPropertyDataSize(object, &address, 0, nil, &size)
    guard status == noErr else { throw QueryFailure(selector: selector, status: status) }
    if size == 0 { return [] }
    var values = [UInt32](repeating: 0, count: Int(size)/4)
    status = AudioObjectGetPropertyData(object, &address, 0, nil, &size, &values)
    guard status == noErr else { throw QueryFailure(selector: selector, status: status) }
    return values
}

func cameraValues(_ object: CMIOObjectID, _ selector: UInt32) throws -> [UInt32] {
    var address = CMIOObjectPropertyAddress(mSelector: selector, mScope: UInt32(kCMIOObjectPropertyScopeGlobal), mElement: UInt32(kCMIOObjectPropertyElementMain))
    var size: UInt32 = 0
    var status = CMIOObjectGetPropertyDataSize(object, &address, 0, nil, &size)
    guard status == noErr else { throw QueryFailure(selector: selector, status: status) }
    if size == 0 { return [] }
    var values = [UInt32](repeating: 0, count: Int(size)/4)
    var used: UInt32 = 0
    status = CMIOObjectGetPropertyData(object, &address, 0, nil, size, &used, &values)
    guard status == noErr else { throw QueryFailure(selector: selector, status: status) }
    return Array(values.prefix(Int(used)/4))
}

var microphones = [[String: Any]]()
for device in try audioValues(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
    if try audioValues(device, kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput).isEmpty { continue }
    let flags = try audioValues(device, kAudioDevicePropertyDeviceIsRunningSomewhere)
    guard let flag = flags.first else { throw CocoaError(.fileReadCorruptFile) }
    microphones.append(["deviceID": device, "runningSomewhere": flag != 0])
}
var cameras = [[String: Any]]()
for device in try cameraValues(CMIOObjectID(kCMIOObjectSystemObject), UInt32(kCMIOHardwarePropertyDevices)) {
    let flags = try cameraValues(device, UInt32(kCMIODevicePropertyDeviceIsRunningSomewhere))
    guard let flag = flags.first else { throw CocoaError(.fileReadCorruptFile) }
    cameras.append(["deviceID": device, "runningSomewhere": flag != 0])
}
let json = try JSONSerialization.data(withJSONObject: ["microphones": microphones, "cameras": cameras], options: [.sortedKeys])
print(String(decoding: json, as: UTF8.self))
