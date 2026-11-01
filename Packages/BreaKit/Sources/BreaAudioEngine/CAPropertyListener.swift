import CoreAudio
import Dispatch

/// A Core Audio property listener that lives as long as this object.
///
/// ## Lifecycle
/// 1. `init` registers a listener block for `selector` on `object`; it fails (returns `nil`)
///    when the HAL refuses the registration.
/// 2. Every change of the property runs `handler` on `queue`.
/// 3. ``cancel()`` or deallocation removes the listener. Cancelling twice is harmless.
final class CAPropertyListener: @unchecked Sendable {
    private let object: AudioObjectID
    private var address: AudioObjectPropertyAddress
    private let queue: DispatchQueue
    private let block: AudioObjectPropertyListenerBlock
    private var isActive = false

    init?(object: AudioObjectID, selector: AudioObjectPropertySelector,
          scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          queue: DispatchQueue, handler: @escaping @Sendable () -> Void) {
        self.object = object
        self.address = CA.address(selector, scope)
        self.queue = queue
        self.block = { _, _ in handler() }
        guard AudioObjectAddPropertyListenerBlock(object, &address, queue, block) == noErr else { return nil }
        isActive = true
    }

    func cancel() {
        guard isActive else { return }
        isActive = false
        AudioObjectRemovePropertyListenerBlock(object, &address, queue, block)
    }

    deinit { cancel() }
}
