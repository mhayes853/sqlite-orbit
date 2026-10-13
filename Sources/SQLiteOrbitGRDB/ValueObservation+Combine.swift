#if canImport(Foundation) && canImport(Dispatch)
  #if canImport(Combine)
    import Combine
    import Foundation

    extension ValueObservation {
      public func publisher(in reader: any DatabaseReader) -> DatabaseValueObservationPublisher<
        Reducer
      > {
        DatabaseValueObservationPublisher(
          observation: self,
          reader: reader,
          scheduler: .async(onQueue: .main)
        )
      }
      public func publisher(
        in reader: any DatabaseReader,
        scheduling scheduler: some ValueObservationScheduler
      ) -> DatabaseValueObservationPublisher<Reducer> {
        DatabaseValueObservationPublisher(observation: self, reader: reader, scheduler: scheduler)
      }
    }
    public struct DatabaseValueObservationPublisher<Reducer: ValueReducer>: Publisher {
      public typealias Output = Reducer.Value
      public typealias Failure = Error
      let observation: ValueObservation<Reducer>
      let reader: any DatabaseReader
      let scheduler: any ValueObservationScheduler
      public func receive<S: Subscriber>(subscriber: S)
      where S.Input == Output, S.Failure == Error {
        subscriber.receive(
          subscription: ObservationCombineSubscription(
            subscriber: subscriber,
            observation: observation,
            reader: reader,
            scheduler: scheduler
          )
        )
      }
    }
    // All state, including the downstream subscriber and its demand, is protected by this lock.
    // A recursive lock permits downstream demand/cancellation from inside receive(_:).
    private final class ObservationCombineSubscription<R: ValueReducer>:
      Subscription,
      @unchecked Sendable
    {
      private let lock = NSRecursiveLock()
      private var subscriber: AnySubscriber<R.Value, Error>?
      private var demand: Subscribers.Demand = .none
      private var pending: R.Value?
      private var token: AnyDatabaseCancellable?
      private var started = false
      private let observation: ValueObservation<R>
      private let reader: any DatabaseReader
      private let scheduler: any ValueObservationScheduler
      init<S: Subscriber>(
        subscriber: S,
        observation: ValueObservation<R>,
        reader: any DatabaseReader,
        scheduler: any ValueObservationScheduler
      ) where S.Input == R.Value, S.Failure == Error {
        self.subscriber = AnySubscriber(subscriber)
        self.observation = observation
        self.reader = reader
        self.scheduler = scheduler
      }
      func request(_ newDemand: Subscribers.Demand) {
        guard newDemand > .none else { return }
        lock.lock()
        guard subscriber != nil else {
          lock.unlock()
          return
        }
        demand += newDemand
        let shouldDrain = pending != nil
        let shouldStart = !started && subscriber != nil
        started = true
        lock.unlock()
        if shouldDrain {
          scheduler.schedule(from: nil) { [weak self] in self?.drainPending() }
        }
        if shouldStart {
          let token = observation.start(
            in: reader,
            scheduling: scheduler,
            onError: { [weak self] in self?.fail($0) },
            onChange: { [weak self] in self?.receive($0) }
          )
          lock.lock()
          if subscriber != nil { self.token = token } else { token.cancel() }
          lock.unlock()
        }
      }
      private func receive(_ value: R.Value) {
        lock.lock()
        defer { lock.unlock() }
        guard subscriber != nil else { return }
        if demand > .none {
          pending = nil
          send(value)
        } else {
          pending = value
        }
      }
      private func drainPending() {
        lock.lock()
        defer { lock.unlock() }
        guard demand > .none, let pending else { return }
        self.pending = nil
        send(pending)
      }
      private func send(_ value: R.Value) {
        guard let subscriber, demand > .none else { return }
        demand -= 1
        demand += subscriber.receive(value)
      }
      private func fail(_ error: Error) {
        lock.lock()
        let subscriber = subscriber
        self.subscriber = nil
        pending = nil
        let token = token
        self.token = nil
        lock.unlock()
        subscriber?.receive(completion: .failure(error))
        token?.cancel()
      }
      func cancel() {
        lock.lock()
        subscriber = nil
        pending = nil
        let token = token
        self.token = nil
        lock.unlock()
        token?.cancel()
      }
      deinit { cancel() }
    }
  #endif

#endif
