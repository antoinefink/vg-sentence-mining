import ScreenCaptureKit

@MainActor final class GameWindowPicker: NSObject, SCContentSharingPickerObserver {
    var onSelection: ((SCContentFilter) -> Void)?
    var onCancel: (() -> Void)?
    var onError: ((Error) -> Void)?

    override init() {
        super.init()
        SCContentSharingPicker.shared.add(self)
    }

    func present() {
        let picker = SCContentSharingPicker.shared
        var configuration = SCContentSharingPickerConfiguration()
        configuration.allowedPickerModes = [.singleWindow]
        configuration.excludedBundleIDs = [Bundle.main.bundleIdentifier ?? "io.antoine.vg-sentence-mining"]
        configuration.allowsChangingSelectedContent = false
        picker.defaultConfiguration = configuration
        picker.isActive = true
        picker.present(using: .window)
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didUpdateWith filter: SCContentFilter, for stream: SCStream?) {
        Task { @MainActor [weak self] in self?.onSelection?(filter) }
    }

    nonisolated func contentSharingPicker(_ picker: SCContentSharingPicker, didCancelFor stream: SCStream?) {
        Task { @MainActor [weak self] in self?.onCancel?() }
    }

    nonisolated func contentSharingPickerStartDidFailWithError(_ error: Error) {
        Task { @MainActor [weak self] in self?.onError?(error) }
    }
}
