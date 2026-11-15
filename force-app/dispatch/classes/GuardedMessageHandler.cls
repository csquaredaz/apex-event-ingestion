/**
 * @description Decorator around one routed handler (ADR 0004). It holds every handler to the
 * contract, so the Composite and the dispatcher can trust what comes back:
 * - A savepoint is set before the call. If the handler throws, its work is rolled back and every
 *   message in the call is `RETRYABLE`. The savepoint is always released, because the platform
 *   refuses callouts while one is active, even after a rollback (probed 2026-11-15).
 * - The result has exactly one entry per message, in input order. A message the handler didn't
 *   answer for is `RETRYABLE`; results for Ids it wasn't given are ignored.
 * - A route whose class can't be resolved answers `RETRYABLE` for every message without a call,
 *   so a fix deployed within the retry window heals it.
 *
 * Uncatchable errors (`LimitException`) end the transaction; Finalizer recovery handles them
 * (ADR 0006).
 * @group Dispatch
 */
public with sharing class GuardedMessageHandler implements IMessageHandler {
  private final String routeName;
  private final IMessageHandler delegate;
  private final String configurationError;

  private GuardedMessageHandler(String routeName, IMessageHandler delegate, String configurationError) {
    this.routeName = routeName;
    this.delegate = delegate;
    this.configurationError = configurationError;
  }

  /**
   * @description Guards a resolved handler.
   * @param routeName The route's `DeveloperName`, for error messages.
   * @param delegate The handler.
   * @return The guarded handler.
   */
  public static GuardedMessageHandler of(String routeName, IMessageHandler delegate) {
    return new GuardedMessageHandler(routeName, delegate, null);
  }

  /**
   * @description Stands in for a route whose handler class can't be used.
   * @param routeName The route's `DeveloperName`.
   * @param error What is wrong with the route.
   * @return A handler that retries every message.
   */
  public static GuardedMessageHandler misconfigured(String routeName, String error) {
    return new GuardedMessageHandler(routeName, null, error);
  }

  /**
   * @description Calls the handler under the guard described on the class. Limits: the handler's
   * own, plus a savepoint (counted as a DML statement) and a rollback when it throws.
   * @param messages The messages.
   * @return One result per message, in input order.
   */
  public List<HandlerResult> handle(List<InboundMessage> messages) {
    if (configurationError != null) {
      return retryAll(messages, configurationError);
    }
    Savepoint beforeHandler = Database.setSavepoint();
    List<HandlerResult> returned;
    try {
      returned = delegate.handle(new List<InboundMessage>(messages));
    } catch (Exception e) {
      Database.rollback(beforeHandler);
      Database.releaseSavepoint(beforeHandler);
      return retryAll(messages, 'Route ' + routeName + ' threw ' + e.getTypeName() + ': ' + e.getMessage());
    }
    Database.releaseSavepoint(beforeHandler);
    return oneResultPerMessage(messages, returned);
  }

  private List<HandlerResult> oneResultPerMessage(List<InboundMessage> messages, List<HandlerResult> returned) {
    Map<Id, HandlerResult> byMessageId = new Map<Id, HandlerResult>();
    for (HandlerResult result : returned == null ? new List<HandlerResult>() : returned) {
      if (result != null && !byMessageId.containsKey(result.getMessageId())) {
        byMessageId.put(result.getMessageId(), result);
      }
    }
    List<HandlerResult> results = new List<HandlerResult>();
    for (InboundMessage message : messages) {
      HandlerResult result = byMessageId.get(message.getMessageId());
      results.add(
        result != null
          ? result
          : HandlerResult.retryable(message.getMessageId(), 'Route ' + routeName + ' returned no result.')
      );
    }
    return results;
  }

  private static List<HandlerResult> retryAll(List<InboundMessage> messages, String error) {
    List<HandlerResult> results = new List<HandlerResult>();
    for (InboundMessage message : messages) {
      results.add(HandlerResult.retryable(message.getMessageId(), error));
    }
    return results;
  }
}
