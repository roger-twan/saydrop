import AppKit
import AVFoundation
import ApplicationServices

public enum PermissionKind { case microphone, accessibility, inputMonitoring }
public enum PermissionStatus: Equatable {
    case allowed, denied, notDetermined, restricted, notRequired
    public var title: String {
        switch self {
        case .allowed: return "Allowed"
        case .denied: return "Not allowed"
        case .notDetermined: return "Not requested"
        case .restricted: return "Restricted by system"
        case .notRequired: return "Requested when needed"
        }
    }
}
public struct PermissionSnapshot {
    public var microphone: PermissionStatus = .notDetermined
    public var accessibility: PermissionStatus = .denied
    public var inputMonitoring: PermissionStatus = .notRequired
}
@MainActor
final class PermissionCoordinator {
    func snapshot(inputMonitoringRequired: Bool = false) -> PermissionSnapshot {
        var result = PermissionSnapshot()
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: result.microphone = .allowed
        case .denied: result.microphone = .denied
        case .restricted: result.microphone = .restricted
        case .notDetermined: result.microphone = .notDetermined
        @unknown default: result.microphone = .restricted
        }
        result.accessibility = AXIsProcessTrusted() ? .allowed : .denied
        result.inputMonitoring = CGPreflightListenEventAccess() ? .allowed : (inputMonitoringRequired ? .denied : .notRequired)
        return result
    }
    func requestMicrophone() async { _ = await AVCaptureDevice.requestAccess(for: .audio) }
    func requestInputMonitoring() { _ = CGRequestListenEventAccess() }
    func openSettings(_ kind: PermissionKind) {
        let pane: String
        switch kind {
        case .microphone: pane = "Privacy_Microphone"
        case .accessibility: pane = "Privacy_Accessibility"
        case .inputMonitoring: pane = "Privacy_ListenEvent"
        }
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") { NSWorkspace.shared.open(url) }
    }
}
