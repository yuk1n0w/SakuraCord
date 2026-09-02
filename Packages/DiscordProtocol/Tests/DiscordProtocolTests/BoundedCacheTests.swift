@testable import DiscordProtocol
import Testing

@Test func `bounded cache evicts the least recently written value`() {
    var cache = BoundedCache<Int, String>(maximumCount: 2)

    cache[1] = "one"
    cache[2] = "two"
    cache[1] = "one updated"
    cache[3] = "three"

    #expect(cache.count == 2)
    #expect(cache[1] == "one updated")
    #expect(cache[2] == nil)
    #expect(cache[3] == "three")
}

@Test func `bounded cache remains capped during sustained insertion`() {
    var cache = BoundedCache<Int, Int>(maximumCount: 32)

    for value in 0 ..< 10_000 {
        cache[value] = value
        #expect(cache.count <= 32)
    }

    #expect(cache[9_967] == nil)
    #expect(cache[9_968] == 9_968)
    #expect(cache[9_999] == 9_999)
}

@Test func `bounded cache removes matching values without corrupting eviction order`() {
    var cache = BoundedCache<Int, Int>(maximumCount: 3)
    cache[1] = 10
    cache[2] = 20
    cache[3] = 30

    cache.removeAll { $0 == 20 }
    cache[4] = 40
    cache[5] = 50

    #expect(cache.count == 3)
    #expect(cache[1] == nil)
    #expect(cache[3] == 30)
    #expect(cache[4] == 40)
    #expect(cache[5] == 50)
}
