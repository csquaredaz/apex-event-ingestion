/**
 * @description Finds the handler for each message type (ADR 0004). Bound to `MessageRouter` by
 * the `DI_Binding.Message_Router` row, so dispatcher tests can stand in handlers.
 * @group Dispatch
 */
public interface IMessageRouter {
  /**
   * @description Builds a handler per routed type: the guarded handler for one route, a
   * `CompositeMessageHandler` for several. A route that can't be resolved still gets a handler,
   * which retries every message.
   * @param messageTypes The message types to route.
   * @return Handlers keyed by the type exactly as given. Types with no active route are left out.
   */
  Map<String, IMessageHandler> handlersFor(Set<String> messageTypes);
}
