/// A binary heap holding at most `capacity` elements, used by the cursor's top-`k` algorithms.
///
/// The ordering closure is supplied per operation rather than stored so callers can hand over a
/// non-escaping predicate. `isCloserToRoot(a, b)` must answer whether `a` belongs above `b`, which
/// makes the root the first element to be evicted once the heap is full.
@usableFromInline
internal struct DatabaseCursorHeap<Element> {
  @usableFromInline
  internal var storage: [Element] = []
  @usableFromInline
  internal let capacity: Int

  @inlinable
  internal init(capacity: Int) {
    self.capacity = capacity
    storage.reserveCapacity(Swift.min(capacity, 1024))
  }

  @inlinable
  internal var isFull: Bool {
    storage.count >= capacity
  }

  @inlinable
  internal var root: Element? {
    storage.first
  }

  /// Offers a value to the heap, evicting the root when the heap is already full.
  @inlinable
  internal mutating func insert(
    _ value: Element,
    by isCloserToRoot: (Element, Element) throws -> Bool
  ) rethrows {
    guard capacity > 0 else { return }
    guard isFull else {
      storage.append(value)
      try siftUp(from: storage.count - 1, by: isCloserToRoot)
      return
    }
    // The root is the worst element kept so far, so the newcomer only earns a slot by beating it.
    guard try isCloserToRoot(storage[0], value) else { return }
    storage[0] = value
    try siftDown(from: 0, by: isCloserToRoot)
  }

  /// Empties the heap, returning its elements ordered from farthest from the root to the root.
  @inlinable
  internal mutating func drain(
    by isCloserToRoot: (Element, Element) throws -> Bool
  ) rethrows -> [Element] {
    var result: [Element] = []
    result.reserveCapacity(storage.count)
    while !storage.isEmpty {
      storage.swapAt(0, storage.count - 1)
      result.append(storage.removeLast())
      try siftDown(from: 0, by: isCloserToRoot)
    }
    result.reverse()
    return result
  }

  @inlinable
  internal mutating func siftUp(
    from index: Int,
    by isCloserToRoot: (Element, Element) throws -> Bool
  ) rethrows {
    var child = index
    while child > 0 {
      let parent = (child - 1) / 2
      guard try isCloserToRoot(storage[child], storage[parent]) else { return }
      storage.swapAt(child, parent)
      child = parent
    }
  }

  @inlinable
  internal mutating func siftDown(
    from index: Int,
    by isCloserToRoot: (Element, Element) throws -> Bool
  ) rethrows {
    var parent = index
    while true {
      var candidate = parent
      let left = parent * 2 + 1
      let right = left + 1
      if left < storage.count, try isCloserToRoot(storage[left], storage[candidate]) {
        candidate = left
      }
      if right < storage.count, try isCloserToRoot(storage[right], storage[candidate]) {
        candidate = right
      }
      guard candidate != parent else { return }
      storage.swapAt(parent, candidate)
      parent = candidate
    }
  }
}
