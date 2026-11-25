import ServiceManagement

/// Whether Forge opens when the Mac does. The Mac keeps the answer, not Forge:
/// it can be changed in System Settings as well.
enum LoginItem {
  static var isOn: Bool { SMAppService.mainApp.status == .enabled }
  /// Turned on here and waiting to be allowed there.
  static var isWaiting: Bool { SMAppService.mainApp.status == .requiresApproval }

  static func set(_ on: Bool) throws {
    if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
  }
}
