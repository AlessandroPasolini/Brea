import Synchronization

/// A lock-free, allocation-free hand-off of a block of values from one control thread to one
/// audio thread, implemented as a triple buffer.
///
/// ## How it works
/// Three slots rotate between three roles: the writer's slot, the reader's slot and a shared
/// middle slot. A single atomic integer holds the middle slot's index (bits 0–1) and a "fresh
/// data" flag (bit 2).
///
/// **Publishing (control thread)**
/// 1. Copy the values into the writer's slot.
/// 2. Atomically swap it into the middle, setting the fresh flag.
/// 3. Take the previous middle slot as the next writer's slot.
///
/// **Consuming (audio thread)**
/// 1. If the fresh flag is clear, return `nil`: nothing new.
/// 2. Otherwise atomically swap the reader's slot into the middle, clearing the flag.
/// 3. Read from the slot that came out of the middle.
///
/// ## Guarantees
/// - The reader always sees a complete snapshot, never one being written.
/// - Neither side ever blocks or allocates.
/// - Intermediate snapshots may be skipped; the reader always gets the newest.
/// - Exactly one thread may publish and exactly one may consume.
public final class ParameterMailbox<Element: BitwiseCopyable>: @unchecked Sendable {
    /// Maximum number of elements per snapshot.
    public let capacity: Int

    private let slots: UnsafeMutablePointer<Element>
    private let counts: UnsafeMutablePointer<Int>
    private let state = Atomic<Int>(1)
    private var writeSlot = 0
    private var readSlot = 2

    private static var freshFlag: Int { 4 }

    public init(capacity: Int, initial: Element) {
        self.capacity = capacity
        slots = .allocate(capacity: capacity * 3)
        slots.initialize(repeating: initial, count: capacity * 3)
        counts = .allocate(capacity: 3)
        counts.initialize(repeating: 0, count: 3)
    }

    deinit {
        slots.deallocate()
        counts.deallocate()
    }

    /// Control thread. Makes `values` the newest snapshot.
    public func publish(_ values: UnsafeBufferPointer<Element>) {
        precondition(values.count <= capacity, "ParameterMailbox overflow")
        let base = slots + writeSlot * capacity
        if let source = values.baseAddress { base.update(from: source, count: values.count) }
        counts[writeSlot] = values.count
        let previous = state.exchange(writeSlot | Self.freshFlag, ordering: .acquiringAndReleasing)
        writeSlot = previous & 3
    }

    /// Audio thread. The newest snapshot, or `nil` when nothing was published since the last call.
    /// The returned buffer stays valid until the next call.
    public func consume() -> UnsafeBufferPointer<Element>? {
        guard state.load(ordering: .relaxed) & Self.freshFlag != 0 else { return nil }
        let previous = state.exchange(readSlot, ordering: .acquiringAndReleasing)
        readSlot = previous & 3
        return UnsafeBufferPointer(start: slots + readSlot * capacity, count: counts[readSlot])
    }
}
