/**
 * @description Test handlers for the dispatch tests. Public, with public inner classes, so
 * `Message_Route__mdt` rows can name them (`DispatchTestHandlers.SucceedAll`) and `Type.forName`
 * reaches them. Inner classes can't hold static state, so every call is recorded on the outer
 * class.
 * @group Testing
 */
@IsTest
public class DispatchTestHandlers {
  /** @description Each handler call, as `<handler>:<message count>`, in call order. */
  public static List<String> calls = new List<String>();
  /** @description The messages of every call, in call order. */
  public static List<List<InboundMessage>> received = new List<List<InboundMessage>>();

  private static void record(String handler, List<InboundMessage> messages) {
    calls.add(handler + ':' + messages.size());
    received.add(messages);
  }

  /**
   * @description An active route row, unsaved, with `Order__c` 1.
   * @param developerName The route name.
   * @param messageType The type it routes.
   * @param handlerClass The handler class name.
   * @return The row.
   */
  public static Message_Route__mdt route(String developerName, String messageType, String handlerClass) {
    return new Message_Route__mdt(
      DeveloperName = developerName,
      Message_Type__c = messageType,
      Handler_Class__c = handlerClass,
      Order__c = 1,
      Is_Active__c = true
    );
  }

  /**
   * @description Sets a route's run order.
   * @param route The row.
   * @param runOrder `Order__c`, or null.
   * @return The same row.
   */
  public static Message_Route__mdt ordered(Message_Route__mdt route, Integer runOrder) {
    route.Order__c = runOrder;
    return route;
  }

  /**
   * @description Messages as handlers see them, with fake Ids.
   * @param count How many.
   * @return The messages, built from `EventIngestionTestFactory.messages`.
   */
  public static List<InboundMessage> messages(Integer count) {
    List<InboundMessage> result = new List<InboundMessage>();
    for (Inbound_Message__c row : EventIngestionTestFactory.messages(count)) {
      row.Id = FakeId.generate(Inbound_Message__c.SObjectType);
      result.add(InboundMessage.fromRecord(row));
    }
    return result;
  }

  /** @description Succeeds for every message. */
  public class SucceedAll implements IMessageHandler {
    /**
     * @description Records the call and succeeds.
     * @param messages The messages.
     * @return One success each.
     */
    public List<HandlerResult> handle(List<InboundMessage> messages) {
      record('SucceedAll', messages);
      List<HandlerResult> results = new List<HandlerResult>();
      for (InboundMessage message : messages) {
        results.add(HandlerResult.success(message.getMessageId()));
      }
      return results;
    }
  }

  /** @description Retries every message. */
  public class RetryAll implements IMessageHandler {
    /**
     * @description Records the call and asks for a retry.
     * @param messages The messages.
     * @return One retryable result each, with the error `busy`.
     */
    public List<HandlerResult> handle(List<InboundMessage> messages) {
      record('RetryAll', messages);
      List<HandlerResult> results = new List<HandlerResult>();
      for (InboundMessage message : messages) {
        results.add(HandlerResult.retryable(message.getMessageId(), 'busy'));
      }
      return results;
    }
  }

  /** @description Fails every message for good. */
  public class FailAll implements IMessageHandler {
    /**
     * @description Records the call and fails.
     * @param messages The messages.
     * @return One fatal result each, with the error `bad payload`.
     */
    public List<HandlerResult> handle(List<InboundMessage> messages) {
      record('FailAll', messages);
      List<HandlerResult> results = new List<HandlerResult>();
      for (InboundMessage message : messages) {
        results.add(HandlerResult.fatal(message.getMessageId(), 'bad payload'));
      }
      return results;
    }
  }

  /** @description Writes a customer account, then throws, so the rollback can be asserted. */
  public class WriteThenThrow implements IMessageHandler {
    /**
     * @description Inserts an `Account` named `Written by handler`, then throws.
     * @param messages The messages.
     * @return Never returns.
     */
    public List<HandlerResult> handle(List<InboundMessage> messages) {
      record('WriteThenThrow', messages);
      insert new Account(Name = 'Written by handler');
      throw new DmlException('downstream record locked');
    }
  }

  /**
   * @description Answers only for the first message, adds a result for an Id it wasn't given,
   * a null entry and a second result for the first message.
   */
  public class Sloppy implements IMessageHandler {
    /**
     * @description Returns an incomplete, noisy result list.
     * @param messages The messages.
     * @return The noisy results.
     */
    public List<HandlerResult> handle(List<InboundMessage> messages) {
      record('Sloppy', messages);
      return new List<HandlerResult>{
        HandlerResult.success(messages[0].getMessageId()),
        HandlerResult.fatal(messages[0].getMessageId(), 'second answer is ignored'),
        null,
        HandlerResult.fatal(FakeId.generate(Inbound_Message__c.SObjectType), 'not mine')
      };
    }
  }

  /** @description Returns null instead of a list. */
  public class ReturnsNull implements IMessageHandler {
    /**
     * @description Returns null.
     * @param messages The messages.
     * @return Null.
     */
    public List<HandlerResult> handle(List<InboundMessage> messages) {
      record('ReturnsNull', messages);
      return null;
    }
  }

  /** @description A route can name this class, but it is not a handler. */
  public class NotAHandler {
  }

  /** @description A handler whose constructor throws. */
  public class FailsToConstruct implements IMessageHandler {
    /** @description Always throws. */
    public FailsToConstruct() {
      throw new IllegalArgumentException('missing configuration');
    }

    /**
     * @description Never reached.
     * @param messages The messages.
     * @return Nothing.
     */
    public List<HandlerResult> handle(List<InboundMessage> messages) {
      return new List<HandlerResult>();
    }
  }
}
