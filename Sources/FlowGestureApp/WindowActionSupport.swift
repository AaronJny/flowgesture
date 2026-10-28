#if os(macOS)
import Foundation

enum WindowActionFailure: Error, Equatable, LocalizedError {
    case noTargetApplication
    case targetApplicationTerminated
    case accessibilityPermissionRequired
    case noFocusedWindow
    case fullScreenUnsupported
    case fullScreenReadOnly
    case exitFullScreenBeforeResizing
    case unreadableGeometry
    case positionReadOnly
    case sizeReadOnly
    case accessibility(operation: String, code: Int32)

    var errorDescription: String? {
        switch self {
        case .noTargetApplication: return "No target application was captured. / 未捕获到目标应用。"
        case .targetApplicationTerminated: return "The target application has quit. / 目标应用已退出。"
        case .accessibilityPermissionRequired: return "Window control needs Accessibility permission. / 窗口操作需要辅助功能权限。"
        case .noFocusedWindow: return "The target application has no accessible focused window. / 目标应用没有可访问的当前窗口。"
        case .fullScreenUnsupported: return "This window does not expose supported full-screen control. / 此窗口不支持可访问的全屏控制。"
        case .fullScreenReadOnly: return "This application does not allow changing this window's full-screen state. / 此应用不允许修改该窗口的全屏状态。"
        case .exitFullScreenBeforeResizing: return "Exit full screen before resizing. Use Toggle Full Screen to enter or leave a full-screen Space. / 请先退出全屏再调整尺寸；切换全屏用于进入或退出全屏空间。"
        case .unreadableGeometry: return "The window does not expose usable position and size. / 无法读取窗口的位置或尺寸。"
        case .positionReadOnly: return "This application does not allow moving this window. / 此应用不允许移动该窗口。"
        case .sizeReadOnly: return "This application does not allow resizing this window. / 此应用不允许调整该窗口大小。"
        case .accessibility(let operation, let code): return "Window operation failed (\(operation), AX error \(code)). / 窗口操作失败（\(operation)，辅助功能错误\(code)）。"
        }
    }
}

enum WindowActionSupport {
    /// An absent state is not assumed to mean windowed. Unsupported apps must not
    /// receive a guessed keyboard shortcut that could perform an unrelated action.
    static func fullScreenTarget(current: Bool?, isSettable: Bool) throws -> Bool {
        guard let current else { throw WindowActionFailure.fullScreenUnsupported }
        guard isSettable else { throw WindowActionFailure.fullScreenReadOnly }
        return !current
    }

    static func validateLayout(isFullScreen: Bool, positionSettable: Bool, sizeSettable: Bool,
                               requiresResize: Bool) throws {
        guard !isFullScreen else { throw WindowActionFailure.exitFullScreenBeforeResizing }
        guard positionSettable else { throw WindowActionFailure.positionReadOnly }
        guard !requiresResize || sizeSettable else { throw WindowActionFailure.sizeReadOnly }
    }
}
#endif
