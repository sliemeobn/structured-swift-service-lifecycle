/// Execute an operation with a graceful shutdown handler that’s immediately invoked if the current task is shutting down gracefully.
///
/// This doesn’t check for graceful shutdown, and always executes the passed operation.
/// The operation executes on the calling execution context and does not suspend by itself, unless the code contained within the closure does.
/// If graceful shutdown occurs while the operation is running, the graceful shutdown handler will execute concurrently with the operation.
///
/// When `withShutdownGracefulHandler` is used in a Task that has already been gracefully shutdown, the `onGracefulShutdown` handler
/// will be executed immediately before operation gets to execute. This allows the `onGracefulShutdown` handler to set some external “shutdown” flag
/// that the operation may be atomically checking for in order to avoid performing any actual work once the operation gets to run.
///
/// A common use-case is to listen to graceful shutdown and use the `ServerQuiescingHelper` from `swift-nio-extras` to
/// trigger the quiescing sequence. Furthermore, graceful shutdown will propagate to any child task that is currently executing
///
/// - Parameters:
///   - operation: The actual operation.
///   - handler: The handler which is invoked once graceful shutdown has been triggered.
@_unsafeInheritExecutor
public func withShutdownGracefulHandler<T>(
    operation: () async throws -> T,
    onGracefulShutdown handler: @Sendable @escaping () -> Void
) async rethrows -> T {
    guard let gracefulShutdownManager = TaskLocals.gracefulShutdownManager else {
        print("WARNING: Trying to setup a graceful shutdown handler inside a task that doesn't have access to the ShutdownGracefulManager. This happens either when unstructured Concurrency is used like Task.detached {} or when you tried to setup a shutdown graceful handler outside the ServiceRunner.run method. Not setting up the handler.")
        return try await operation()
    }

    // We have to keep track of our handler here to remove it once the operation is finished.
    let handlerID = await gracefulShutdownManager.registerHandler(handler)

    let result = try await operation()

    // Great the operation is finished. If we have a number we need to remove the handler.
    if let handlerID {
        await gracefulShutdownManager.removeHandler(handlerID)
    }

    return result
}

@_spi(Testing)
public enum TaskLocals {
    @TaskLocal
    @_spi(Testing)
    public static var gracefulShutdownManager: GracefulShutdownManager?
}

extension Task {
    /// Indicates that the task should shutdown gracefully.
    ///
    /// Calling this method on a task that doesn’t support graceful shutdown has no effect.
    ///
    /// - Note: This method is mostly relevant for testing graceful shutdown. In your application, the ``ServiceRunner``
    /// should be the instance that triggers the graceful shutdown.
    public func shutdownGracefully() async {
        guard let gracefulShutdownManager = TaskLocals.gracefulShutdownManager else {
            print("WARNING: Trying to shutdown gracefully inside a task that doesn't have access to the ShutdownGracefulManager. This happens either when unstructured Concurrency is used like Task.detached {} or when you tried to shutdown gracefully outside the ServiceRunner.run method.")
            return
        }

        await gracefulShutdownManager.shutdownGracefully()
    }
}

extension TaskGroup {
    /// Indicates all of the tasks in the group to shutdown gracefully.
    ///
    /// Calling this method on a task that doesn’t support graceful shutdown has no effect.
    ///
    /// - Note: This method is mostly relevant for testing graceful shutdown. In your application, the ``ServiceRunner``
    /// should be the instance that triggers the graceful shutdown.
    public func shutdownGracefullyAll() async {
        guard let gracefulShutdownManager = TaskLocals.gracefulShutdownManager else {
            print("WARNING: Trying to shutdown gracefully inside a task that doesn't have access to the ShutdownGracefulManager. This happens either when unstructured Concurrency is used like Task.detached {} or when you tried to shutdown gracefully outside the ServiceRunner.run method.")
            return
        }

        await gracefulShutdownManager.shutdownGracefully()
    }
}

extension ThrowingTaskGroup {
    /// Indicates all of the tasks in the group to shutdown gracefully.
    ///
    /// Calling this method on a task that doesn’t support graceful shutdown has no effect.
    ///
    /// - Note: This method is mostly relevant for testing graceful shutdown. In your application, the ``ServiceRunner``
    /// should be the instance that triggers the graceful shutdown.
    public func shutdownGracefullyAll() async {
        guard let gracefulShutdownManager = TaskLocals.gracefulShutdownManager else {
            print("WARNING: Trying to shutdown gracefully inside a task that doesn't have access to the ShutdownGracefulManager. This happens either when unstructured Concurrency is used like Task.detached {} or when you tried to shutdown gracefully outside the ServiceRunner.run method.")
            return
        }

        await gracefulShutdownManager.shutdownGracefully()
    }
}

@_spi(Testing)
public actor GracefulShutdownManager {
    struct Handler {
        /// The id of the handler.
        var id: UInt64
        /// The actual handler.
        var handler: () -> Void
    }

    /// The currently registered handlers.
    private var handlers = [Handler]()
    /// A counter to assign a unique number to each handler.
    private var handlerCounter: UInt64 = 0
    /// A boolean indicating if we have been shutdown already.
    private var isShuttingDown = false

    @_spi(Testing)
    public init() {}

    func registerHandler(_ handler: @Sendable @escaping () -> Void) -> UInt64? {
        if self.isShuttingDown {
            handler()
            return nil
        } else {
            defer {
                self.handlerCounter += 1
            }
            let handlerID = self.handlerCounter
            self.handlers.append(.init(id: handlerID, handler: handler))

            return handlerID
        }
    }

    func removeHandler(_ handlerID: UInt64) {
        guard let index = self.handlers.firstIndex(where: { $0.id == handlerID }) else {
            // This can happen because if shutdownGracefully ran while the operation was still in progress
            return
        }

        self.handlers.remove(at: index)
    }

    @_spi(Testing)
    public func shutdownGracefully() {
        guard !self.isShuttingDown else {
            return
        }
        self.isShuttingDown = true

        for handler in self.handlers {
            handler.handler()
        }

        self.handlers.removeAll()
    }
}