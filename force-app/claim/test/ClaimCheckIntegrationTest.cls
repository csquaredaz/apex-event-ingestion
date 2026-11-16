/**
 * @description Integration tests for Claim Check (ADR 0008), end to end: a producer uploads a file,
 * publishes `Inbound_Message_Event__e` with its `Payload_Ref__c`, and the real trigger, store,
 * processor job, dispatcher and resolver hand the file's text to a handler. Stored rows are read
 * `WITH SYSTEM_MODE`.
 *
 * Subject:  Inbound_Message_Event__e → MessageStore (inspect) → MessageProcessorJob → MessageDispatcher (resolve)
 * Mocks:    IMessageRoutesSelector (one route to a recording handler)
 * Bulk:     covered by the store and resolver unit tests (one inspect and one resolve per batch)
 * Negative: a claim on another user's file; a file deleted before dispatch
 */
@IsTest
private class ClaimCheckIntegrationTest {
  private static void useRecordingRoute() {
    Application.Service.setMock(
      IMessageRoutesSelector.class,
      new Mocks()
        .stubReturn(
          'selectActiveByMessageTypes',
          new List<Message_Route__mdt>{
            DispatchTestHandlers.route(
              'Orders',
              EventIngestionTestFactory.MESSAGE_TYPE,
              'DispatchTestHandlers.SucceedAll'
            )
          }
        )
        .stub(IMessageRoutesSelector.class)
    );
  }

  private static Inbound_Message_Event__e claimedEvent(Id versionId) {
    Inbound_Message_Event__e event = EventIngestionTestFactory.event(EventIngestionTestFactory.SOURCE, 'ORD-BIG');
    event.Payload__c = null;
    event.Payload_Ref__c = versionId;
    return event;
  }

  /** A JSON body over Payload__c's 131,072 characters, so it can only travel by claim. */
  private static String largeBody() {
    return '{"orderNumber":"ORD-BIG","lines":"' + 'x'.repeat(200000) + '"}';
  }

  private static List<Inbound_Message__c> stored() {
    return [
      SELECT Payload__c, Payload_Ref__c, Payload_Size__c, Status__c, Last_Error__c
      FROM Inbound_Message__c
      WITH SYSTEM_MODE
    ];
  }

  @IsTest
  static void publish_claimOnOwnFile_isStoredAndTheHandlerGetsTheFileText() {
    useRecordingRoute();
    String body = largeBody();
    Id versionId = EventIngestionTestFactory.claimFile(body);

    Test.startTest();
    Database.SaveResult save = EventBus.publish(claimedEvent(versionId));
    Test.getEventBus().deliver();
    Test.stopTest();

    Assert.isTrue(save.isSuccess(), 'Published: ' + save.getErrors());
    List<Inbound_Message__c> rows = stored();
    Assert.areEqual(1, rows.size(), 'Stored');
    Assert.areEqual(versionId, rows[0].Payload_Ref__c, 'The claim is kept');
    Assert.isNull(rows[0].Payload__c, 'Nothing inline');
    Assert.areEqual(body.length(), rows[0].Payload_Size__c, 'The file size, for the dispatch budget');
    Assert.areEqual(MessageStatuses.PROCESSED, rows[0].Status__c, 'Processed: ' + rows[0].Last_Error__c);
    InboundMessage handled = DispatchTestHandlers.received[0][0];
    Assert.areEqual(body, handled.getPayload(), 'The handler gets the file text');
    Assert.areEqual(versionId, handled.getPayloadRef(), 'And can see it came by claim');
  }

  @IsTest
  static void publish_claimOnAnotherUsersFile_isRejectedAndNotStored() {
    useRecordingRoute();
    Id versionId = EventIngestionTestFactory.claimFile(largeBody());
    User publisher = EventIngestionTestFactory.minimumAccessUser('Event_Ingestion_Publisher');

    System.runAs(publisher) {
      Test.startTest();
      Database.SaveResult save = EventBus.publish(claimedEvent(versionId));
      Test.getEventBus().deliver();
      Test.stopTest();
      Assert.isTrue(save.isSuccess(), 'The publish itself succeeds: ' + save.getErrors());
    }

    Assert.areEqual(0, stored().size(), 'The processor can read every file, so the uploader decides');
    Assert.areEqual(0, DispatchTestHandlers.received.size(), 'No handler ran');
  }

  @IsTest
  static void publish_fileDeletedBeforeDispatch_isDead() {
    useRecordingRoute();
    Id versionId = EventIngestionTestFactory.claimFile(largeBody());

    Test.startTest();
    EventBus.publish(claimedEvent(versionId));
    Test.getEventBus().deliver();
    delete [SELECT Id FROM ContentDocument WHERE LatestPublishedVersionId = :versionId];
    Test.stopTest();

    List<Inbound_Message__c> rows = stored();
    Assert.areEqual(MessageStatuses.DEAD, rows[0].Status__c, 'Retrying cannot bring the file back');
    Assert.isTrue(rows[0].Last_Error__c.contains('could not be loaded'), rows[0].Last_Error__c);
    Assert.areEqual(0, DispatchTestHandlers.received.size(), 'The handler never saw it');
  }
}
