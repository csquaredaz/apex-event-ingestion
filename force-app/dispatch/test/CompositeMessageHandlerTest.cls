/**
 * @description Tests for `CompositeMessageHandler`, with the in-memory handlers in
 * `DispatchTestHandlers`.
 *
 * Subject:  CompositeMessageHandler.handle
 * Mocks:    DispatchTestHandlers (succeed, retry, fail)
 * Bulk:     200 messages through 3 children → 3 calls, 200 merged results in input order
 * Negative: no children; equal-severity failures keep both errors
 */
@IsTest
private class CompositeMessageHandlerTest {
  private static CompositeMessageHandler composite(List<IMessageHandler> children) {
    return new CompositeMessageHandler(children);
  }

  @IsTest
  static void handle_children_runInOrderAndEachSeesEveryMessage() {
    List<InboundMessage> messages = DispatchTestHandlers.messages(3);

    composite(new List<IMessageHandler>{ new DispatchTestHandlers.RetryAll(), new DispatchTestHandlers.SucceedAll() })
      .handle(messages);

    Assert.areEqual(new List<String>{ 'RetryAll:3', 'SucceedAll:3' }, DispatchTestHandlers.calls, 'Route order');
  }

  @IsTest
  static void handle_successAndRetryable_retryableWins() {
    List<InboundMessage> messages = DispatchTestHandlers.messages(1);

    List<HandlerResult> results = composite(
        new List<IMessageHandler>{ new DispatchTestHandlers.SucceedAll(), new DispatchTestHandlers.RetryAll() }
      )
      .handle(messages);

    Assert.isTrue(results[0].isRetryable(), 'Retryable outranks success');
    Assert.areEqual('busy', results[0].getError(), 'The failing child\'s error');
  }

  @IsTest
  static void handle_retryableThenFatal_fatalWins() {
    List<HandlerResult> results = composite(
        new List<IMessageHandler>{ new DispatchTestHandlers.RetryAll(), new DispatchTestHandlers.FailAll() }
      )
      .handle(DispatchTestHandlers.messages(1));

    Assert.isTrue(results[0].isFatal(), 'Fatal outranks retryable, whatever the order');
    Assert.areEqual('bad payload', results[0].getError(), 'Only the fatal error');
  }

  @IsTest
  static void handle_twoFailuresOfEqualSeverity_keepsBothErrors() {
    List<HandlerResult> retried = composite(
        new List<IMessageHandler>{ new DispatchTestHandlers.RetryAll(), new DispatchTestHandlers.RetryAll() }
      )
      .handle(DispatchTestHandlers.messages(1));
    List<HandlerResult> failed = composite(
        new List<IMessageHandler>{ new DispatchTestHandlers.FailAll(), new DispatchTestHandlers.FailAll() }
      )
      .handle(DispatchTestHandlers.messages(1));

    Assert.isTrue(retried[0].isRetryable(), 'Still retryable');
    Assert.areEqual('busy; busy', retried[0].getError(), 'Both retry errors');
    Assert.isTrue(failed[0].isFatal(), 'Still fatal');
    Assert.areEqual('bad payload; bad payload', failed[0].getError(), 'Both fatal errors');
  }

  @IsTest
  static void handle_allSucceed_isSuccess() {
    List<HandlerResult> results = composite(
        new List<IMessageHandler>{ new DispatchTestHandlers.SucceedAll(), new DispatchTestHandlers.SucceedAll() }
      )
      .handle(DispatchTestHandlers.messages(1));

    Assert.isTrue(results[0].isSuccess(), 'Success');
    Assert.isNull(results[0].getError(), 'No error');
  }

  @IsTest
  static void handle_200Messages_mergesOneResultEachInInputOrder() {
    List<InboundMessage> messages = DispatchTestHandlers.messages(200);

    Test.startTest();
    List<HandlerResult> results = composite(
        new List<IMessageHandler>{
          new DispatchTestHandlers.SucceedAll(),
          new DispatchTestHandlers.RetryAll(),
          new DispatchTestHandlers.SucceedAll()
        }
      )
      .handle(messages);
    Test.stopTest();

    Assert.areEqual(3, DispatchTestHandlers.calls.size(), 'One call per child, not per message');
    Assert.areEqual(200, results.size(), 'One result per message');
    for (Integer i = 0; i < 200; i++) {
      Assert.areEqual(messages[i].getMessageId(), results[i].getMessageId(), 'Input order at ' + i);
      Assert.isTrue(results[i].isRetryable(), 'Worst result at ' + i);
    }
  }

  @IsTest
  static void constructor_noChildren_throwsIllegalArgument() {
    try {
      composite(new List<IMessageHandler>());
      Assert.fail('Expected IllegalArgumentException');
    } catch (IllegalArgumentException e) {
      Assert.isTrue(e.getMessage().contains('at least one'), e.getMessage());
    }
  }
}
