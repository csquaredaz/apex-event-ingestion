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
   * payload), plus 1 through `IPayloadResolver` when any message is claimed; one handler call per
   * route per message type; bulk-safe at 200.
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
    List<Inbound_Message__c> rows = selector.selectWithPayloadByIds(messageIds);
    Map<String, List<InboundMessage>> messagesByType = group(rows, resolveClaims(rows), resultsById);
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

  /** Loads every claimed payload in one call; none when no message is claimed (ADR 0008). */
  private static Map<String, String> resolveClaims(List<Inbound_Message__c> rows) {
    Set<String> refs = new Set<String>();
    for (Inbound_Message__c row : rows) {
      if (String.isNotBlank(row.Payload_Ref__c)) {
        refs.add(row.Payload_Ref__c);
      }
    }
    if (refs.isEmpty()) {
      return new Map<String, String>();
    }
    return ((IPayloadResolver) Application.Service.newInstance(IPayloadResolver.class)).resolve(refs);
  }

  /**
   * Groups the messages by type with their payloads. A claim that can't be loaded can't heal by
   * retrying, so that message is FATAL here and never reaches a handler; an operator replays it
   * from Dead.
   */
  private static Map<String, List<InboundMessage>> group(
    List<Inbound_Message__c> rows,
    Map<String, String> claimedPayloads,
    Map<Id, HandlerResult> resultsById
  ) {
    Map<String, List<InboundMessage>> messagesByType = new Map<String, List<InboundMessage>>();
    for (Inbound_Message__c row : rows) {
      Boolean claimed = String.isNotBlank(row.Payload_Ref__c);
      if (claimed && !claimedPayloads.containsKey(row.Payload_Ref__c)) {
        resultsById.put(
          row.Id,
          HandlerResult.fatal(
            row.Id,
            'The claimed payload ' +
              row.Payload_Ref__c +
              ' could not be loaded: the ContentVersion is missing, not visible or not UTF-8 text.'
          )
        );
        continue;
      }
      if (!messagesByType.containsKey(row.Message_Type__c)) {
        messagesByType.put(row.Message_Type__c, new List<InboundMessage>());
      }
      messagesByType.get(row.Message_Type__c)
        .add(InboundMessage.fromRecord(row, claimed ? claimedPayloads.get(row.Payload_Ref__c) : row.Payload__c));
    }
    return messagesByType;
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
