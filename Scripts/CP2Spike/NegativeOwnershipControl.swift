// Expected-failure SIL compile, isolated from the pooled producer's separate diagnostic.
nonisolated final class CP2MutableProbe { var writes = 0 }
@MainActor final class CP2ProbeReceiver {
    private var retained: CP2MutableProbe?
    func accept(_ value: sending CP2MutableProbe) { retained = value }
}
actor CP2InvalidProducer {
    func violate(receiver: CP2ProbeReceiver) async {
        let value = CP2MutableProbe()
        let retainedWriter = value
        await receiver.accept(value)
        retainedWriter.writes += 1 // Must be diagnosed: producer writes after sending.
    }
}
