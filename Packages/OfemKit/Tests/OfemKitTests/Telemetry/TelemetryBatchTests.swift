@testable import OfemKit
import Testing

@Suite("TelemetryBatch")
struct TelemetryBatchTests {
    @Test("enqueue adds events and drain returns them")
    func enqueueAndDrain() async {
        let batch = TelemetryBatch(maxSize: 10)

        await batch.enqueue(TelemetryEvent(name: "ev1"))
        await batch.enqueue(TelemetryEvent(name: "ev2"))

        let drained = await batch.drain()
        #expect(drained.count == 2)
        #expect(drained[0].name == "ev1")
        #expect(drained[1].name == "ev2")
    }

    @Test("drain clears the buffer")
    func drainClearsBuffer() async {
        let batch = TelemetryBatch(maxSize: 10)
        await batch.enqueue(TelemetryEvent(name: "ev"))
        _ = await batch.drain()
        let second = await batch.drain()
        #expect(second.isEmpty)
    }

    @Test("enqueue drops oldest when maxSize reached")
    func overflowDropsOldest() async {
        let batch = TelemetryBatch(maxSize: 3)
        for i in 0 ..< 5 {
            await batch.enqueue(TelemetryEvent(name: "ev\(i)"))
        }
        let events = await batch.drain()
        #expect(events.count == 3)
        // ev0 and ev1 were dropped.
        #expect(events[0].name == "ev2")
        #expect(events[1].name == "ev3")
        #expect(events[2].name == "ev4")
    }

    @Test("enqueue returns true when buffer hits maxSize")
    func enqueueSignalsFullOnOverflow() async {
        let batch = TelemetryBatch(maxSize: 2)
        let notFull = await batch.enqueue(TelemetryEvent(name: "ev1"))
        let full = await batch.enqueue(TelemetryEvent(name: "ev2"))
        #expect(!notFull)
        #expect(full)
    }

    @Test("requeue places events at the front")
    func requeueFront() async {
        let batch = TelemetryBatch(maxSize: 10)
        await batch.enqueue(TelemetryEvent(name: "new"))
        // Re-queue two older events — they should appear before "new".
        let older = [TelemetryEvent(name: "old1"), TelemetryEvent(name: "old2")]
        await batch.requeue(older)

        let events = await batch.drain()
        #expect(events.count == 3)
        #expect(events[0].name == "old1")
        #expect(events[1].name == "old2")
        #expect(events[2].name == "new")
    }

    @Test("requeue trims to maxSize from the oldest end")
    func requeueRespectsCapacity() async {
        let batch = TelemetryBatch(maxSize: 3)
        // Enqueue 2 new events.
        await batch.enqueue(TelemetryEvent(name: "new1"))
        await batch.enqueue(TelemetryEvent(name: "new2"))
        // Re-queue 2 old events — combined is 4, cap is 3. Oldest (old1) dropped.
        await batch.requeue([TelemetryEvent(name: "old1"), TelemetryEvent(name: "old2")])

        let events = await batch.drain()
        #expect(events.count == 3)
        #expect(events[0].name == "old2")
        #expect(events[1].name == "new1")
        #expect(events[2].name == "new2")
    }

    @Test("count reflects current buffer size")
    func countReflectsSize() async {
        let batch = TelemetryBatch(maxSize: 10)
        #expect(await batch.count == 0)
        await batch.enqueue(TelemetryEvent(name: "a"))
        #expect(await batch.count == 1)
        await batch.enqueue(TelemetryEvent(name: "b"))
        #expect(await batch.count == 2)
        _ = await batch.drain()
        #expect(await batch.count == 0)
    }
}
