/**
 * @description The default `IMessageDispatcher` (ADR 0004): a stateless service that loads
 * messages through `IInboundMessagesSelector`, routes them through `IMessageRouter` and collects
 * the handlers' results. It performs no DML of its own; the handlers' writes share the caller's
 * transaction, and the processor job (ADR 0006) turns the results into status changes.
 * @group Dispatch
 */
public with sharing class MessageDispatcher implements IMessageDispatcher {
  /**
   * @description See `IMessageDispatcher.dispatch`. Limits: 1 SOQL (selector, user mode, with
   * payload); one handler call per route per message type; bulk-safe at 200.
   * @param messageIds The messages to dispatch.
   * @return One result per message found, keyed by message Id.
   */
  public Map<Id, HandlerResult> dispatch(Set<Id> messageIds) {
    Map<Id, HandlerResult> resultsById = new Map<Id, HandlerResult>();
    if (messageIds == null || messageIds.isEmpty()) {
      return resultsById;
    }
    IInboundMessagesSelector selector = (IInboundMessagesSelector) Application.Selector.newInstance(
      Inbound_Message__c.SObjectType
    );
    Map<String, List<InboundMessage>> messagesByType = new Map<String, List<InboundMessage>>();
    for (Inbound_Message__c row : selector.selectWithPayloadByIds(messageIds)) {
      if (!messagesByType.containsKey(row.Message_Type__c)) {
        messagesByType.put(row.Message_Type__c, new List<InboundMessage>());
      }
      messagesByType.get(row.Message_Type__c).add(InboundMessage.fromRecord(row));
    }
    if (messagesByType.isEmpty()) {
      return resultsById;
    }

    Map<String, IMessageHandler> handlersByType = ((IMessageRouter) Application.Service.newInstance(
        IMessageRouter.class
      ))
      .handlersFor(messagesByType.keySet());
    for (String messageType : messagesByType.keySet()) {
      List<InboundMessage> messages = messagesByType.get(messageType);
      IMessageHandler handler = handlersByType.get(messageType);
      List<HandlerResult> results = handler == null ? unrouted(messageType, messages) : handler.handle(messages);
      collect(messages, results, resultsById);
    }
    return resultsById;
  }

  /** No route means nobody handles the type: the message goes to Dead and can be replayed. */
  private static List<HandlerResult> unrouted(String messageType, List<InboundMessage> messages) {
    List<HandlerResult> results = new List<HandlerResult>();
    for (InboundMessage message : messages) {
      results.add(
        HandlerResult.fatal(message.getMessageId(), 'No active Message_Route__mdt for type ' + messageType + '.')
      );
    }
    return results;
  }

  /** Keeps one result per message of this type; a gap is retried, as `GuardedMessageHandler` does. */
  private static void collect(
    List<InboundMessage> messages,
    List<HandlerResult> results,
    Map<Id, HandlerResult> resultsById
  ) {
    Map<Id, HandlerResult> returned = new Map<Id, HandlerResult>();
    for (HandlerResult result : results == null ? new List<HandlerResult>() : results) {
      if (result != null && !returned.containsKey(result.getMessageId())) {
        returned.put(result.getMessageId(), result);
      }
    }
    for (InboundMessage message : messages) {
      Id messageId = message.getMessageId();
      HandlerResult result = returned.get(messageId);
      resultsById.put(
        messageId,
        result != null ? result : HandlerResult.retryable(messageId, 'The handler returned no result.')
      );
    }
  }
}
