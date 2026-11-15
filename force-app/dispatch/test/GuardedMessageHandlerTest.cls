/**
 * @description Tests for `GuardedMessageHandler`: the result contract, and the savepoint with
 * real DML and a mocked callout.
 *
 * Subject:  GuardedMessageHandler.handle
 * Mocks:    DispatchTestHandlers; HttpCalloutMock for the callout after the guard
 * Bulk:     200 messages → 1 handler call, 200 results, 1 savepoint
 * Negative: handler throws after DML; missing, duplicate, foreign and null results; null list;
 *           misconfigured route
 */
@IsTest
private class GuardedMessageHandlerTest {
  private class OkCallout implements HttpCalloutMock {
    public HttpResponse respond(HttpRequest request) {
      HttpResponse response = new HttpResponse();
      response.setStatusCode(200);
      return response;
    }
  }

  @IsTest
  static void handle_handlerSucceeds_passesItsResultsThrough() {
    List<InboundMessage> messages = DispatchTestHandlers.messages(2);

    List<HandlerResult> results = GuardedMessageHandler.of('Orders', new DispatchTestHandlers.SucceedAll())
      .handle(messages);

    Assert.areEqual(2, results.size(), 'One result per message');
    Assert.isTrue(results[0].isSuccess() && results[1].isSuccess(), 'The handler\'s results');
    Assert.areEqual(messages[1].getMessageId(), results[1].getMessageId(), 'Input order');
  }

  @IsTest
  static void handle_handlerThrowsAfterDml_rollsBackAndRetriesEveryMessage() {
    List<InboundMessage> messages = DispatchTestHandlers.messages(2);

    Test.startTest();
    List<HandlerResult> results = GuardedMessageHandler.of('Orders', new DispatchTestHandlers.WriteThenThrow())
      .handle(messages);
    Test.stopTest();

    Assert.areEqual(0, [SELECT COUNT() FROM Account WHERE Name = 'Written by handler'], 'Handler DML rolled back');
    Assert.isTrue(results[0].isRetryable() && results[1].isRetryable(), 'Every message retried');
    Assert.areEqual(
      'Route Orders threw System.DmlException: downstream record locked',
      results[0].getError(),
      'The route, the exception type and its message'
    );
  }

  @IsTest
  static void handle_afterAThrow_releasesTheSavepointSoCalloutsStillWork() {
    Test.setMock(HttpCalloutMock.class, new OkCallout());
    GuardedMessageHandler.of('Orders', new DispatchTestHandlers.ReturnsNull()).handle(DispatchTestHandlers.messages(1));
    GuardedMessageHandler.of('Orders', new DispatchTestHandlers.WriteThenThrow())
      .handle(DispatchTestHandlers.messages(1));

    HttpRequest request = new HttpRequest();
    request.setEndpoint('https://example.com/');
    request.setMethod('GET');
    HttpResponse response = new Http().send(request);

    Assert.areEqual(200, response.getStatusCode(), 'An active savepoint would block this callout');
  }

  @IsTest
  static void handle_incompleteNoisyResults_answersEachMessageOnce() {
    List<InboundMessage> messages = DispatchTestHandlers.messages(2);

    List<HandlerResult> results = GuardedMessageHandler.of('Orders', new DispatchTestHandlers.Sloppy())
      .handle(messages);

    Assert.areEqual(2, results.size(), 'Foreign and null results dropped');
    Assert.isTrue(results[0].isSuccess(), 'The first answer for a message wins');
    Assert.isTrue(results[1].isRetryable(), 'An unanswered message is retried');
    Assert.areEqual('Route Orders returned no result.', results[1].getError(), 'Says why');
  }

  @IsTest
  static void handle_handlerReturnsNull_retriesEveryMessage() {
    List<HandlerResult> results = GuardedMessageHandler.of('Orders', new DispatchTestHandlers.ReturnsNull())
      .handle(DispatchTestHandlers.messages(2));

    Assert.isTrue(results[0].isRetryable() && results[1].isRetryable(), 'No results: retry all');
  }

  @IsTest
  static void handle_misconfigured_retriesWithoutCallingAnything() {
    List<HandlerResult> results = GuardedMessageHandler.misconfigured('Orders', 'class missing')
      .handle(DispatchTestHandlers.messages(2));

    Assert.isTrue(results[0].isRetryable() && results[1].isRetryable(), 'Retry all');
    Assert.areEqual('class missing', results[0].getError(), 'The configuration error');
    Assert.areEqual(0, Limits.getDmlStatements(), 'No savepoint spent');
  }

  @IsTest
  static void handle_200Messages_oneCallAndOneSavepoint() {
    List<InboundMessage> messages = DispatchTestHandlers.messages(200);

    Test.startTest();
    List<HandlerResult> results = GuardedMessageHandler.of('Orders', new DispatchTestHandlers.SucceedAll())
      .handle(messages);
    Integer dmlStatements = Limits.getDmlStatements();
    Test.stopTest();

    Assert.areEqual(200, results.size(), 'One result per message');
    Assert.areEqual(new List<String>{ 'SucceedAll:200' }, DispatchTestHandlers.calls, 'One bulk call');
    Assert.isTrue(dmlStatements <= 2, 'Only the savepoint counts: ' + dmlStatements);
  }
}
