// Compiled through SIL separately by verify-ownership.sh; never an app/test source member.
@MainActor
func cp2PositiveControl(producer: CutoutSpikeProducer, store: CutoutSpikeStore,
                        frame: CutoutSpikeFrame) async throws {
    let completed = try await producer.make()
    store.publish(frame, pixels: completed)
}
