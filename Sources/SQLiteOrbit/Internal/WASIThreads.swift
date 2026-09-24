// swift-format-ignore-file
// These declarations must keep the C names of the functions they bind.

// The WASILibc module Swift ships reads wasi-libc's `sys/types.h`, which names the pthread types,
// but not its `pthread.h`, which declares the functions. These are the functions the pthread
// executor needs, declared as wasi-libc exports them on a target built with threads.
#if os(WASI) && _runtime(_multithreaded)
  import WASILibc

  @_extern(c)
  func pthread_mutex_init(
    _ mutex: UnsafeMutablePointer<pthread_mutex_t>,
    _ attributes: UnsafePointer<pthread_mutexattr_t>?
  ) -> Int32

  @_extern(c)
  func pthread_mutex_destroy(_ mutex: UnsafeMutablePointer<pthread_mutex_t>) -> Int32

  @_extern(c)
  func pthread_mutex_lock(_ mutex: UnsafeMutablePointer<pthread_mutex_t>) -> Int32

  @_extern(c)
  func pthread_mutex_unlock(_ mutex: UnsafeMutablePointer<pthread_mutex_t>) -> Int32

  @_extern(c)
  func pthread_cond_init(
    _ condition: UnsafeMutablePointer<pthread_cond_t>,
    _ attributes: UnsafePointer<pthread_condattr_t>?
  ) -> Int32

  @_extern(c)
  func pthread_cond_destroy(_ condition: UnsafeMutablePointer<pthread_cond_t>) -> Int32

  @_extern(c)
  func pthread_cond_wait(
    _ condition: UnsafeMutablePointer<pthread_cond_t>,
    _ mutex: UnsafeMutablePointer<pthread_mutex_t>
  ) -> Int32

  @_extern(c)
  func pthread_cond_timedwait(
    _ condition: UnsafeMutablePointer<pthread_cond_t>,
    _ mutex: UnsafeMutablePointer<pthread_mutex_t>,
    _ deadline: UnsafePointer<timespec>
  ) -> Int32

  @_extern(c)
  func pthread_cond_broadcast(_ condition: UnsafeMutablePointer<pthread_cond_t>) -> Int32

  @_extern(c)
  func pthread_attr_init(_ attributes: UnsafeMutablePointer<pthread_attr_t>) -> Int32

  @_extern(c)
  func pthread_attr_destroy(_ attributes: UnsafeMutablePointer<pthread_attr_t>) -> Int32

  @_extern(c)
  func pthread_attr_setdetachstate(
    _ attributes: UnsafeMutablePointer<pthread_attr_t>,
    _ state: Int32
  ) -> Int32

  @_extern(c)
  func pthread_attr_getstacksize(
    _ attributes: UnsafePointer<pthread_attr_t>,
    _ size: UnsafeMutablePointer<Int>
  ) -> Int32

  @_extern(c)
  func pthread_attr_setstacksize(
    _ attributes: UnsafeMutablePointer<pthread_attr_t>,
    _ size: Int
  ) -> Int32

  @_extern(c)
  func pthread_create(
    _ thread: UnsafeMutablePointer<pthread_t?>,
    _ attributes: UnsafePointer<pthread_attr_t>?,
    _ body: @convention(c) (UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer?,
    _ context: UnsafeMutableRawPointer?
  ) -> Int32

  @_extern(c)
  func pthread_self() -> pthread_t

  @_extern(c)
  func pthread_equal(_ lhs: pthread_t, _ rhs: pthread_t) -> Int32

  let PTHREAD_CREATE_DETACHED: Int32 = 1
#endif
