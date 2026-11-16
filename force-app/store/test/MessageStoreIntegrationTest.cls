/**
 * @description Integration tests for the message store with real DML and the real bindings, run
 * as Minimum Access users: the Processor permission set allows appends; no permission set or the
 * Viewer permission set throws. Rows are counted `WITH SYSTEM_MODE` so the assertions don't depend
 * on the running user's access.
 *
 * Subject:  IMessageStore.append through Application.Service
 * Mocks:    none
 * Bulk:     200 messages → 200 rows, 1 DML statement, no SOQL
 * Negative: duplicates across calls and within a batch, a rejected first copy, an oversized
 *           payload, users without create access, and a claim on another user's file (ADR 0008)
 */
@IsTest
private class MessageStoreIntegrationTest {
  private static IMessageStore store() {
    return (IMessageStore) Application.Service.newInstance(IMessageStore.class);
  }

  private static Integer storedCount() {
    return [SELECT COUNT() FROM Inbound_Message__c WITH SYSTEM_MODE];
  }

  @IsTest
  static void append_asProcessor_storesReceivedRowsKeyedBySourceAndId() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    List<AppendResult> results;
    System.runAs(processor) {
      Test.startTest();
      results = store().append(EventIngestionTestFactory.messages(3));
      Test.stopTest();
    }

    Assert.isTrue(results[0].isAccepted(), 'Accepted');
    Inbound_Message__c row = [
      SELECT Idempotency_Key__c, Status__c, Attempts__c, OwnerId
      FROM Inbound_Message__c
      WHERE Id = :results[0].getMessageId()
      WITH SYSTEM_MODE
    ];
    Assert.areEqual('erp:ORD-0000', row.Idempotency_Key__c, 'Key');
    Assert.areEqual(MessageStatuses.RECEIVED, row.Status__c, 'Received');
    Assert.areEqual(0, row.Attempts__c, 'No attempts');
    Assert.areEqual(processor.Id, row.OwnerId, 'Owned by the user that appended it');
    Assert.areEqual(3, storedCount(), 'Three rows');
  }

  @IsTest
  static void append_sameMessagesTwice_secondCallReturnsDuplicatesOfTheStoredRows() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    List<AppendResult> first;
    List<AppendResult> second;
    System.runAs(processor) {
      first = store().append(EventIngestionTestFactory.messages(5));
      Test.startTest();
      second = store().append(EventIngestionTestFactory.messages(5));
      Test.stopTest();
    }

    for (Integer i = 0; i < 5; i++) {
      Assert.isTrue(second[i].isDuplicate(), 'Redelivery ' + i + ' is a duplicate');
      Assert.areEqual(first[i].getMessageId(), second[i].getMessageId(), 'Redelivery points at the stored row');
    }
    Assert.areEqual(5, storedCount(), 'Nothing stored twice');
  }

  @IsTest
  static void append_repeatsWithinOneBatch_firstCopyWinsAndTheRestPointAtIt() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    List<Inbound_Message__c> messages = new List<Inbound_Message__c>{
      EventIngestionTestFactory.message('erp', 'ORD-1'),
      EventIngestionTestFactory.message('erp', 'ORD-1'),
      EventIngestionTestFactory.message('erp', 'ord-1'),
      EventIngestionTestFactory.message('erp', 'ORD-1')
    };
    List<AppendResult> results;
    System.runAs(processor) {
      Test.startTest();
      results = store().append(messages);
      Test.stopTest();
    }

    Assert.isTrue(results[0].isAccepted(), 'First copy stored');
    Assert.isTrue(results[1].isDuplicate() && results[3].isDuplicate(), 'Later copies are duplicates');
    Assert.areEqual(results[0].getMessageId(), results[1].getMessageId(), 'Copy points at the first');
    Assert.areEqual(results[0].getMessageId(), results[3].getMessageId(), 'Copy points at the first');
    Assert.isTrue(results[2].isAccepted(), 'The key is case-sensitive: ord-1 is a different message');
    Assert.areEqual(2, storedCount(), 'ORD-1 and ord-1');
  }

  @IsTest
  static void append_firstCopyRejected_laterValidCopyIsAccepted() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    Inbound_Message__c untyped = EventIngestionTestFactory.message('erp', 'ORD-1');
    untyped.Message_Type__c = null;
    List<AppendResult> results;
    System.runAs(processor) {
      Test.startTest();
      results = store()
        .append(new List<Inbound_Message__c>{ untyped, EventIngestionTestFactory.message('erp', 'ORD-1') });
      Test.stopTest();
    }

    Assert.isTrue(results[0].isRejected(), 'Missing type rejected');
    Assert.isTrue(results[0].getError().startsWith('REQUIRED_FIELD_MISSING'), results[0].getError());
    Assert.isTrue(results[1].isAccepted(), 'The valid copy is not a duplicate of a rejected one');
  }

  @IsTest
  static void append_oversizedPayload_rejectsOnlyThatMessage() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    List<Inbound_Message__c> messages = EventIngestionTestFactory.messages(2);
    messages[0].Payload__c = 'x'.repeat(131073);
    List<AppendResult> results;
    System.runAs(processor) {
      Test.startTest();
      results = store().append(messages);
      Test.stopTest();
    }

    Assert.isTrue(results[0].isRejected(), 'Over the 131,072-character field');
    Assert.isTrue(results[0].getError().startsWith('STRING_TOO_LONG'), results[0].getError());
    Assert.isTrue(results[1].isAccepted(), 'The other message is unaffected');
  }

  @IsTest
  static void append_200Messages_storesAllInOneStatementWithoutQueries() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    List<AppendResult> results;
    Integer statements;
    Integer queries;
    System.runAs(processor) {
      Test.startTest();
      results = store().append(EventIngestionTestFactory.messages(200));
      statements = Limits.getDmlStatements();
      queries = Limits.getQueries();
      Test.stopTest();
    }

    Integer accepted = 0;
    for (AppendResult result : results) {
      accepted += result.isAccepted() ? 1 : 0;
    }
    Assert.areEqual(200, accepted, 'All accepted');
    Assert.areEqual(200, storedCount(), 'All stored');
    Assert.areEqual(1, statements, 'One DML statement');
    Assert.areEqual(0, queries, 'No SOQL without duplicates');
  }

  @IsTest
  static void append_200Redeliveries_returnDuplicatesWithOneQuery() {
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    List<AppendResult> results;
    Integer queries;
    System.runAs(processor) {
      store().append(EventIngestionTestFactory.messages(200));
      Test.startTest();
      results = store().append(EventIngestionTestFactory.messages(200));
      queries = Limits.getQueries();
      Test.stopTest();
    }

    Integer duplicatesWithIds = 0;
    for (AppendResult result : results) {
      duplicatesWithIds += result.isDuplicate() && result.getMessageId() != null ? 1 : 0;
    }
    Assert.areEqual(200, duplicatesWithIds, 'Every redelivery resolves to its stored row');
    Assert.areEqual(1, queries, 'One lookup for all duplicates');
    Assert.areEqual(200, storedCount(), 'Nothing stored twice');
  }

  @IsTest
  static void append_withoutPermissionSet_throwsAndStoresNothing() {
    User noAccess = EventIngestionTestFactory.minimumAccessUser(null);
    System.runAs(noAccess) {
      try {
        store().append(EventIngestionTestFactory.messages(2));
        Assert.fail('Expected MessageStoreException');
      } catch (MessageStoreException e) {
        Assert.isTrue(e.getMessage().contains('Event_Ingestion_Processor'), 'Names the fix: ' + e.getMessage());
      }
    }
    Assert.areEqual(0, storedCount(), 'Nothing stored');
  }

  @IsTest
  static void append_objectCreateWithoutFieldAccess_throwsInsteadOfRejecting() {
    User partial = EventIngestionTestFactory.minimumAccessUser(null);
    System.runAs(new User(Id = UserInfo.getUserId())) {
      PermissionSet objectOnly = new PermissionSet(Name = 'Aei_Object_Only_Test', Label = 'AEI Object Only Test');
      insert objectOnly;
      insert new ObjectPermissions(
        ParentId = objectOnly.Id,
        SobjectType = 'Inbound_Message__c',
        PermissionsRead = true,
        PermissionsCreate = true
      );
      insert new PermissionSetAssignment(PermissionSetId = objectOnly.Id, AssigneeId = partial.Id);
    }
    System.runAs(partial) {
      try {
        store().append(EventIngestionTestFactory.messages(1));
        Assert.fail('Expected MessageStoreException');
      } catch (MessageStoreException e) {
        Assert.isTrue(e.getMessage().contains('producer fields'), e.getMessage());
      }
    }
    Assert.areEqual(0, storedCount(), 'Nothing stored, nothing wrongly rejected');
  }

  @IsTest
  static void append_asViewer_throwsBecauseViewersCannotCreate() {
    User viewer = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.VIEWER);
    System.runAs(viewer) {
      try {
        store().append(EventIngestionTestFactory.messages(1));
        Assert.fail('Expected MessageStoreException');
      } catch (MessageStoreException e) {
        Assert.isTrue(e.getMessage().contains('cannot create'), e.getMessage());
      }
    }
    Assert.areEqual(0, storedCount(), 'Nothing stored');
  }

  @IsTest
  static void append_asProcessorClaimingItsOwnFile_storesTheClaimAndOnlyThat() {
    Id othersFile = EventIngestionTestFactory.claimFile('{"theirs":true}');
    User processor = EventIngestionTestFactory.minimumAccessUser(EventIngestionTestFactory.PROCESSOR);
    List<AppendResult> results;
    Id ownFile;
    System.runAs(processor) {
      ownFile = EventIngestionTestFactory.claimFile('{"mine":true}');
      List<Inbound_Message__c> messages = EventIngestionTestFactory.messages(2);
      for (Inbound_Message__c message : messages) {
        message.Payload__c = null;
      }
      messages[0].Payload_Ref__c = ownFile;
      messages[1].Payload_Ref__c = othersFile;
      Test.startTest();
      results = store().append(messages);
      Test.stopTest();
    }

    Assert.isTrue(results[0].isAccepted(), 'Its own upload: ' + results[0].getError());
    Assert.isTrue(results[1].isRejected(), 'Another user\'s file is not visible to it');
    Inbound_Message__c row = [
      SELECT Payload_Ref__c, Payload_Size__c
      FROM Inbound_Message__c
      WHERE Id = :results[0].getMessageId()
      WITH SYSTEM_MODE
    ];
    Assert.areEqual(ownFile, row.Payload_Ref__c, 'The claim');
    Assert.areEqual(13, row.Payload_Size__c, 'The file size');
  }
}
