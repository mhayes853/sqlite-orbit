#if GRDB
  import Foundation
  import StructuredQueriesSQLite

  /// Drives an aggregate function body, which consumes its rows as a `Sequence`.
  ///
  /// SQLite pushes rows one at a time through an `xStep` callback, but an aggregate body pulls them
  /// with `for element in arguments`. Bridging the two means the body has to run somewhere it can
  /// block: it runs on the cooperative pool and blocks on ``AggregateFunctionStream`` until SQLite
  /// pushes the next row or signals the end of the group.
  ///
  /// > Note: The body occupies a cooperative pool thread for as long as its aggregation runs, and
  /// > spends most of that time blocked waiting for SQLite. Enough concurrent aggregations can
  /// > therefore starve the pool. If that becomes a problem, give this work a custom executor
  /// > rather than putting it back on a queue of its own.
  protocol AggregateFunctionInvocationProtocol: AnyObject {
    /// Runs the aggregate body to completion. Called once, off the SQLite thread.
    func run()
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
    private let completion = AggregateFunctionCompletion()

    init(_ function: Function) {
      self.function = function
      // Erased before capture so the task does not close over `Function`'s metatype, and retained
      // by the task until the body returns, so the invocation outlives this initializer even though
      // SQLite holds it only through its aggregate context.
      nonisolated(unsafe) let invocation: any AggregateFunctionInvocationProtocol = self
      Task.detached(priority: .userInitiated) {
        invocation.run()
      }
    }

    func run() {
      let result: QueryBinding
      do {
        result = try function.invoke(stream)
      } catch {
        result = .invalid(error)
      }
      // The body may have returned without draining every row, so stop holding producers up.
      stream.stopBuffering()
      completion.complete(result)
    }

    func step(_ decoder: inout some QueryDecoder) throws {
      stream.send(try function.step(&decoder))
    }

    func finish() {
      stream.finish()
    }

    /// The aggregated result, waiting for the body to return.
    var result: QueryBinding {
      completion.wait()
    }
  }

  /// Hands the body's result back to the SQLite thread that asked for it.
  private final class AggregateFunctionCompletion {
    private let condition = NSCondition()
    private var result: QueryBinding?

    func complete(_ result: QueryBinding) {
      condition.withLock {
        self.result = result
        condition.broadcast()
      }
    }

    /// Blocks until the body returns. Called on SQLite's own thread, never a cooperative one.
    func wait() -> QueryBinding {
      condition.withLock {
        while result == nil {
          condition.wait()
        }
        return result ?? .null
      }
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
