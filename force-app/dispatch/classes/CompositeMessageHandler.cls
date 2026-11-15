/**
 * @description Composite of the handlers routed to one message type (ADR 0004). Every child
 * handles every message, in route order, and the most severe result per message wins: `FATAL`
 * over `RETRYABLE` over `SUCCESS`. Failures of equal severity keep every error.
 *
 * Children are independent Commands. One child failing doesn't undo another's work, so a retried
 * message reaches the children that already succeeded again; that is why handlers must be
 * idempotent. The router builds it from `GuardedMessageHandler` children, which return one result
 * per message and never throw.
 * @group Dispatch
 */
public with sharing class CompositeMessageHandler implements IMessageHandler {
  private final List<IMessageHandler> children;

  /**
   * @description Builds the Composite.
   * @param children The handlers, in run order.
   * @throws IllegalArgumentException If there are no children.
   */
  public CompositeMessageHandler(List<IMessageHandler> children) {
    if (children == null || children.isEmpty()) {
      throw new IllegalArgumentException('A CompositeMessageHandler needs at least one handler.');
    }
    this.children = new List<IMessageHandler>(children);
  }

  /**
   * @description Runs every child and merges the results. Limits: the children's, one call each.
   * @param messages The messages.
   * @return One result per message, in input order: the most severe across the children.
   */
  public List<HandlerResult> handle(List<InboundMessage> messages) {
    Map<Id, HandlerResult> worstByMessageId = new Map<Id, HandlerResult>();
    for (IMessageHandler child : children) {
      for (HandlerResult result : child.handle(messages)) {
        Id messageId = result.getMessageId();
        worstByMessageId.put(messageId, worse(worstByMessageId.get(messageId), result));
      }
    }
    List<HandlerResult> results = new List<HandlerResult>();
    for (InboundMessage message : messages) {
      results.add(worstByMessageId.get(message.getMessageId()));
    }
    return results;
  }

  private static HandlerResult worse(HandlerResult current, HandlerResult candidate) {
    if (current == null) {
      return candidate;
    }
    Integer currentSeverity = current.getOutcome().ordinal();
    Integer candidateSeverity = candidate.getOutcome().ordinal();
    if (candidateSeverity != currentSeverity) {
      return candidateSeverity > currentSeverity ? candidate : current;
    }
    if (current.isSuccess()) {
      return current;
    }
    String error = current.getError() + '; ' + candidate.getError();
    return current.isFatal()
      ? HandlerResult.fatal(current.getMessageId(), error)
      : HandlerResult.retryable(current.getMessageId(), error);
  }
}
