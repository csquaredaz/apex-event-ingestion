/**
 * @description Runs stored messages through their routed handlers and reports one result per
 * message (ADR 0004). It writes no status: the processor job owns the lifecycle. Resolve it with
 * `(IMessageDispatcher) Application.Service.newInstance(IMessageDispatcher.class)`; the
 * `DI_Binding.Message_Dispatcher` row binds `MessageDispatcher`.
 * @group Public API
 */
public interface IMessageDispatcher {
  /**
   * @description Loads the messages with their payloads, groups them by type and calls each
   * type's handler once. A type with no active route is `FATAL`; a route that can't be resolved,
   * a handler that throws and a message a handler didn't answer for are `RETRYABLE`.
   * Limits: 1 SOQL, no SOQL for routes, then per message type 1 handler call per route with a
   * savepoint around it (2 DML statements counted).
   * @param messageIds The messages to dispatch. Null or empty returns an empty map.
   * @return A result per message the running user can see, keyed by message Id. Ids that aren't
   * found are left out.
   */
  Map<Id, HandlerResult> dispatch(Set<Id> messageIds);
}
