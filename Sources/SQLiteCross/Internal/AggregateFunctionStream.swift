#if GRDB
  import Foundation
  import StructuredQueriesSQLite

  /// Drives an aggregate function body, which consumes its rows as a `Sequence`.
  ///
  /// SQLite pushes rows one at a time through an `xStep` callback, but an aggregate body pulls
  /// them with `for element in arguments`. Bridging the two means the body has to run somewhere it
  /// can block: it runs on its own queue and blocks on ``AggregateFunctionStream`` until SQLite
  /// pushes the next row or signals the end of the group.
  ///
  /// A ported copy of what swift-structured-queries does, since it does not ship the target that
  /// holds it.
  protocol AggregateFunctionInvocationProtocol: AnyObject {
    func step(_ decoder: inout some QueryDecoder) throws
    func finish()
    var result: QueryBinding { get }
  }

  /// A concrete box, so an invocation of any function type can be handed to SQLite's aggregate
  /// context through `Unmanaged`.
  final class AnyAggregateFunctionInvocation {
    private let base: any AggregateFunctionInvocationProtocol

    init(_ base: any AggregateFunctionInvocationProtocol) {
      self.base = base
    }

    func step(_ decoder: inout some QueryDecoder) throws {
      try base.step(&decoder)
    }

    func finish() {
      base.finish()
    }

    var result: QueryBinding {
      base.result
    }
  }

  final class AggregateFunctionInvocation<Function: AggregateDatabaseFunction>:
    AggregateFunctionInvocationProtocol
  {
    private let function: Function
    private let stream = AggregateFunctionStream<Function.Element>()
    private let queue: DispatchQueue
    private var _result: QueryBinding?

    init(_ function: Function) {
      self.function = function
      self.queue = DispatchQueue(
        label: "co.pointfree.SQLiteCross.AggregateDatabaseFunction.\(function.name)"
      )
      nonisolated(unsafe) let invocation = self
      queue.async {
        invocation.start()
      }
    }

    private func start() {
      do {
        _result = try function.invoke(stream)
      } catch {
        _result = .invalid(error)
      }
      // The body returned without draining every row, so stop holding producers up.
      stream.stopBuffering()
    }

    func step(_ decoder: inout some QueryDecoder) throws {
      stream.send(try function.step(&decoder))
    }

    func finish() {
      stream.finish()
    }

    /// The aggregated result, waiting for the body to return.
    var result: QueryBinding {
      queue.sync { _result ?? .null }
    }
  }

  /// A bounded queue handing elements from SQLite's callback thread to an aggregate body.
  private final class AggregateFunctionStream<Element>: Sequence {
    private static var capacity: Int { 64 }

    private let condition = NSCondition()
    private var buffer: [Element] = []
    private var head = 0
    private var isFinished = false
    private var isBuffering = true

    private var count: Int { buffer.count - head }

    func send(_ element: Element) {
      condition.withLock {
        while isBuffering && count >= Self.capacity {
          condition.wait()
        }
        guard isBuffering else { return }
        buffer.append(element)
        condition.broadcast()
      }
    }

    func finish() {
      condition.withLock {
        isFinished = true
        condition.broadcast()
      }
    }

    func stopBuffering() {
      condition.withLock {
        isBuffering = false
        buffer.removeAll()
        head = 0
        condition.broadcast()
      }
    }

    func makeIterator() -> Iterator { Iterator(base: self) }

    struct Iterator: IteratorProtocol {
      fileprivate let base: AggregateFunctionStream

      mutating func next() -> Element? {
        base.condition.withLock {
          while base.count == 0 && !base.isFinished {
            base.condition.wait()
          }
          guard base.count > 0 else { return nil }
          let element = base.buffer[base.head]
          base.head += 1
          if base.head >= AggregateFunctionStream.capacity {
            base.buffer.removeFirst(base.head)
            base.head = 0
          }
          base.condition.broadcast()
          return element
        }
      }
    }
  }
#endif
