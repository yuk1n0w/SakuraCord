struct BoundedCache<Key: Hashable, Value> {
    private struct RecencyEntry {
        let key: Key
        let generation: UInt64
    }

    let maximumCount: Int

    private var storage: [Key: Value] = [:]
    private var generationByKey: [Key: UInt64] = [:]
    private var recencyEntries: [RecencyEntry] = []
    private var recencyStartIndex = 0
    private var nextGeneration: UInt64 = 0

    init(maximumCount: Int) {
        precondition(maximumCount > 0)
        self.maximumCount = maximumCount
    }

    var count: Int {
        storage.count
    }

    var values: Dictionary<Key, Value>.Values {
        storage.values
    }

    subscript(key: Key) -> Value? {
        get { storage[key] }
        set {
            guard let newValue else {
                storage[key] = nil
                generationByKey[key] = nil
                compactRecencyIfNeeded()
                return
            }

            storage[key] = newValue
            recordWrite(for: key)
            evictIfNeeded()
            compactRecencyIfNeeded()
        }
    }

    mutating func removeAll(where shouldRemove: (Value) throws -> Bool) rethrows {
        let keys = try storage.compactMap { key, value in
            try shouldRemove(value) ? key : nil
        }
        for key in keys {
            storage[key] = nil
            generationByKey[key] = nil
        }
        compactRecencyIfNeeded(force: true)
    }

    private mutating func recordWrite(for key: Key) {
        nextGeneration &+= 1
        generationByKey[key] = nextGeneration
        recencyEntries.append(RecencyEntry(key: key, generation: nextGeneration))
    }

    private mutating func evictIfNeeded() {
        while storage.count > maximumCount, recencyStartIndex < recencyEntries.count {
            let entry = recencyEntries[recencyStartIndex]
            recencyStartIndex += 1
            guard generationByKey[entry.key] == entry.generation else { continue }
            storage[entry.key] = nil
            generationByKey[entry.key] = nil
        }
    }

    private mutating func compactRecencyIfNeeded(force: Bool = false) {
        let liveEntryLimit = max(maximumCount * 4, 1_024)
        let consumedEntryLimit = max(maximumCount, 512)
        guard force
            || recencyEntries.count - recencyStartIndex > liveEntryLimit
            || recencyStartIndex > consumedEntryLimit
        else { return }

        recencyEntries = generationByKey
            .map { RecencyEntry(key: $0.key, generation: $0.value) }
            .sorted { $0.generation < $1.generation }
        recencyStartIndex = 0
    }
}
