/**
 * @description Unit tests for `MessageStore`, with Stub API mocks for `IPartialDml`,
 * `IInboundMessagesSelector` and `IPayloadResolver`, so no row is written.
 *
 * Subject:  MessageStore.append
 * Mocks:    IPartialDml (fake SaveResults), IInboundMessagesSelector, IPayloadResolver (claims)
 * Bulk:     200 messages → 1 insert call, 200 results in input order, no query; 200 claims → 1 inspect
 * Negative: null/empty input, missing key parts, DUPLICATE_VALUE, other DML errors, invisible stored row,
 *           an inline payload and a claim together, a claim on another producer's file, an unusable
 *           claim, a producer list of the wrong size
 */
@IsTest
private class MessageStoreTest {
  private static Mocks dmlMock;
  private static Mocks selectorMock;
  private static Mocks resolverMock;
  private static User processorUser;

  private static void useMocks(List<Database.SaveResult> saves, List<Inbound_Message__c> stored) {
    dmlMock = new Mocks().stubReturn('insertPartial', saves);
    Application.Service.setMock(IPartialDml.class, dmlMock.stub(IPartialDml.class));
    selectorMock = new Mocks().stubReturn('selectByIdempotencyKeys', stored);
    Application.Selector.setMock(
      Inbound_Message__c.SObjectType,
      (ISelector) selectorMock.stub(IInboundMessagesSelector.class)
    );
    resolverMock = new Mocks().stubReturn('inspect', new Map<String, PayloadClaim>());
    Application.Service.setMock(IPayloadResolver.class, resolverMock.stub(IPayloadResolver.class));
  }

  private static List<Inbound_Message__c> insertedRows() {
    return (List<Inbound_Message__c>) dmlMock.argumentsOf('insertPartial', 0)[0];
  }

  /**
   * `append` checks the running user's create access for real, even with the DML mocked, so the
   * tests run as a Minimum Access user with `Event_Ingestion_Processor`, never as the admin, who
   * has no package permission set in the package build org. Created once per test; tests that
   * measure limits call it before `Test.startTest()`.
   */
  private static User processor() {
    if (processorUser == null) {
      processorUser = EventIngestionTestFactory.minimumAccessUser('Event_Ingestion_Processor');
    }
    return processorUser;
  }

  private static List<AppendResult> appendAsProcessor(List<Inbound_Message__c> messages) {
    return appendAsProcessor(messages, null);
  }

  private static List<AppendResult> appendAsProcessor(List<Inbound_Message__c> messages, List<Id> producerIds) {
    List<AppendResult> results;
    System.runAs(processor()) {
      results = new MessageStore().append(messages, producerIds);
    }
    return results;
  }

  private static Inbound_Message__c storedRow(String key) {
    return new Inbound_Message__c(Id = FakeId.generate(Inbound_Message__c.SObjectType), Idempotency_Key__c = key);
  }

  @IsTest
  static void bindings_resolveTheDefaultAdapters() {
    Assert.isInstanceOfType(
      Application.Service.newInstance(IMessageStore.class),
      MessageStore.class,
      'DI_Binding.Message_Store'
    );
    Assert.isInstanceOfType(
      Application.Service.newInstance(IPartialDml.class),
      UserModePartialDml.class,
      'DI_Binding.User_Mode_Partial_Dml'
    );
  }

  @IsTest
  static void append_nullOrEmpty_returnsNothingWithoutDml() {
    useMocks(new List<Database.SaveResult>(), new List<Inbound_Message__c>());

    Assert.areEqual(0, appendAsProcessor(null).size(), 'Null input');
    Assert.areEqual(0, appendAsProcessor(new List<Inbound_Message__c>()).size(), 'Empty input');
    dmlMock.verify('insertPartial', 0);
  }

  @IsTest
  static void append_newMessages_acceptsEachWithItsNewId() {
    Id first = FakeId.generate(Inbound_Message__c.SObjectType);
    Id second = FakeId.generate(Inbound_Message__c.SObjectType);
    useMocks(
      new List<Database.SaveResult>{
        EventIngestionTestFactory.savedResult(first),
        EventIngestionTestFactory.savedResult(second)
      },
      null
    );

    processor(); // setup DML and queries stay outside the measured block
    Test.startTest();
    List<AppendResult> results = appendAsProcessor(EventIngestionTestFactory.messages(2));
    Test.stopTest();

    Assert.areEqual(AppendResult.Outcome.ACCEPTED, results[0].getOutcome(), 'Outcome');
    Assert.isTrue(results[0].isAccepted() && results[1].isAccepted(), 'Both accepted');
    Assert.areEqual(first, results[0].getMessageId(), 'First Id');
    Assert.areEqual(second, results[1].getMessageId(), 'Second Id');
    Assert.areEqual('erp:ORD-0000', results[0].getIdempotencyKey(), 'Key on the result');
    Assert.isNull(results[0].getError(), 'No error when accepted');
    selectorMock.verify('selectByIdempotencyKeys', 0);
  }

  @IsTest
  static void append_message_copiesProducerFieldsAndStartsTheLifecycle() {
    useMocks(new List<Database.SaveResult>{ EventIngestionTestFactory.savedResult(null) }, null);
    Inbound_Message__c message = EventIngestionTestFactory.message('erp', 'ORD-7');
    message.Status__c = MessageStatuses.PROCESSED;
    message.Attempts__c = 4;
    message.Last_Error__c = 'stale';
    message.Processed_At__c = Datetime.now();

    appendAsProcessor(new List<Inbound_Message__c>{ message });

    Inbound_Message__c row = insertedRows()[0];
    Assert.areEqual('erp:ORD-7', row.Idempotency_Key__c, 'Key');
    Assert.areEqual(message.Message_Type__c, row.Message_Type__c, 'Type');
    Assert.areEqual(message.Payload__c, row.Payload__c, 'Payload');
    Assert.areEqual(message.Payload__c.length(), row.Payload_Size__c, 'Inline size recorded for the dispatch budget');
    Assert.isNull(row.Payload_Ref__c, 'No claim');
    Assert.areEqual(message.Correlation_Id__c, row.Correlation_Id__c, 'Correlation Id');
    Assert.areEqual(message.Occurred_At__c, row.Occurred_At__c, 'Occurred at');
    Assert.areEqual(MessageStatuses.RECEIVED, row.Status__c, 'Lifecycle starts at Received, whatever the caller set');
    Assert.areEqual(0, row.Attempts__c, 'No attempts yet');
    Assert.isNull(row.Last_Error__c, 'Caller lifecycle fields are not copied');
    Assert.isNull(row.Processed_At__c, 'Caller lifecycle fields are not copied');
  }

  @IsTest
  static void append_missingKeyParts_rejectsThemAndInsertsTheRest() {
    useMocks(new List<Database.SaveResult>{ EventIngestionTestFactory.savedResult(null) }, null);
    List<Inbound_Message__c> messages = new List<Inbound_Message__c>{
      EventIngestionTestFactory.message(null, 'ORD-1'),
      null,
      EventIngestionTestFactory.message('erp', 'ORD-2'),
      EventIngestionTestFactory.message('erp', '')
    };

    List<AppendResult> results = appendAsProcessor(messages);

    Assert.areEqual(4, results.size(), 'One result per message');
    Assert.isTrue(results[0].isRejected() && results[0].getError().contains('Source__c'), results[0].getError());
    Assert.isTrue(results[1].isRejected() && results[1].getError().contains('null'), results[1].getError());
    Assert.isTrue(results[2].isAccepted(), 'The valid message is still stored');
    Assert.isTrue(
      results[3].isRejected() && results[3].getError().contains('External_Message_Id__c'),
      results[3].getError()
    );
    Assert.isNull(results[0].getIdempotencyKey(), 'No key when a part is missing');
    Assert.areEqual(1, insertedRows().size(), 'Only the valid message reaches the database');
  }

  @IsTest
  static void append_noValidMessages_skipsTheInsert() {
    useMocks(null, null);

    List<AppendResult> results = appendAsProcessor(
      new List<Inbound_Message__c>{ EventIngestionTestFactory.message('erp:eu', 'ORD-1') }
    );

    Assert.isTrue(results[0].isRejected(), 'Ambiguous source rejected');
    dmlMock.verify('insertPartial', 0);
  }

  @IsTest
  static void append_duplicateValue_returnsTheStoredIdFromOneQuery() {
    Inbound_Message__c stored = storedRow('erp:ORD-0001');
    Inbound_Message__c otherCase = storedRow('erp:ord-0001');
    useMocks(
      new List<Database.SaveResult>{
        EventIngestionTestFactory.savedResult(FakeId.generate(Inbound_Message__c.SObjectType)),
        EventIngestionTestFactory.failedResult(StatusCode.DUPLICATE_VALUE, 'duplicate value found'),
        EventIngestionTestFactory.failedResult(StatusCode.DUPLICATE_VALUE, 'duplicate value found')
      },
      // A row whose key differs only in case must not be taken for the stored copy.
      new List<Inbound_Message__c>{ otherCase, stored }
    );
    List<Inbound_Message__c> messages = EventIngestionTestFactory.messages(2);
    messages.add(EventIngestionTestFactory.message('erp', 'ORD-0001'));

    List<AppendResult> results = appendAsProcessor(messages);

    Assert.isTrue(results[0].isAccepted(), 'New message accepted');
    Assert.isTrue(results[1].isDuplicate() && results[2].isDuplicate(), 'Both copies are duplicates');
    Assert.areEqual(stored.Id, results[1].getMessageId(), 'Duplicate points at the exact-case stored row');
    Assert.areEqual(stored.Id, results[2].getMessageId(), 'Every copy points at the same row');
    selectorMock.verify('selectByIdempotencyKeys', 1);
    Assert.areEqual(
      new Set<String>{ 'erp:ORD-0001' },
      (Set<String>) selectorMock.argumentsOf('selectByIdempotencyKeys', 0)[0],
      'Only duplicate keys are looked up'
    );
  }

  @IsTest
  static void append_duplicateTheUserCannotSee_returnsANullId() {
    useMocks(
      new List<Database.SaveResult>{ EventIngestionTestFactory.failedResult(StatusCode.DUPLICATE_VALUE, 'dup') },
      new List<Inbound_Message__c>()
    );

    List<AppendResult> results = appendAsProcessor(EventIngestionTestFactory.messages(1));

    Assert.isTrue(results[0].isDuplicate(), 'Still a duplicate');
    Assert.isNull(results[0].getMessageId(), 'No Id for a row the user cannot see');
  }

  @IsTest
  static void append_otherDmlError_rejectsWithTheStatusCodeAndMessage() {
    useMocks(
      new List<Database.SaveResult>{
        EventIngestionTestFactory.failedResult(
          StatusCode.REQUIRED_FIELD_MISSING,
          'Required fields are missing: [Message Type]'
        )
      },
      null
    );

    List<AppendResult> results = appendAsProcessor(EventIngestionTestFactory.messages(1));

    Assert.isTrue(results[0].isRejected(), 'Rejected');
    Assert.areEqual(
      'REQUIRED_FIELD_MISSING: Required fields are missing: [Message Type]',
      results[0].getError(),
      'Code and message'
    );
    Assert.areEqual('erp:ORD-0000', results[0].getIdempotencyKey(), 'A rejected message with a key keeps it');
    Assert.isNull(results[0].getMessageId(), 'No Id when rejected');
    selectorMock.verify('selectByIdempotencyKeys', 0);
  }

  @IsTest
  static void append_200Messages_oneInsertCallAndResultsInInputOrder() {
    List<Database.SaveResult> saves = new List<Database.SaveResult>();
    List<Id> ids = new List<Id>();
    for (Integer i = 0; i < 200; i++) {
      ids.add(FakeId.generate(Inbound_Message__c.SObjectType));
      saves.add(EventIngestionTestFactory.savedResult(ids[i]));
    }
    useMocks(saves, null);

    processor(); // setup DML and queries stay outside the measured block
    Test.startTest();
    List<AppendResult> results = appendAsProcessor(EventIngestionTestFactory.messages(200));
    Integer queries = Limits.getQueries();
    Test.stopTest();

    dmlMock.verify('insertPartial', 1);
    Assert.areEqual(200, insertedRows().size(), 'One statement for the batch');
    Assert.areEqual(200, results.size(), 'One result per message');
    Assert.areEqual(ids[199], results[199].getMessageId(), 'Results follow input order');
    Assert.areEqual('erp:ORD-0199', results[199].getIdempotencyKey(), 'Keys follow input order');
    Assert.areEqual(0, queries, 'No SOQL without duplicates');
  }

  private static Inbound_Message__c claimed(String externalId, String ref) {
    Inbound_Message__c message = EventIngestionTestFactory.message(EventIngestionTestFactory.SOURCE, externalId);
    message.Payload__c = null;
    message.Payload_Ref__c = ref;
    return message;
  }

  private static void useClaims(Map<String, PayloadClaim> claims) {
    resolverMock = new Mocks().stubReturn('inspect', claims);
    Application.Service.setMock(IPayloadResolver.class, resolverMock.stub(IPayloadResolver.class));
  }

  @IsTest
  static void append_inlineOnly_neverInspects() {
    useMocks(new List<Database.SaveResult>{ EventIngestionTestFactory.savedResult(null) }, null);

    List<AppendResult> results = appendAsProcessor(EventIngestionTestFactory.messages(1));

    Assert.isTrue(results[0].isAccepted(), 'Stored without a claim check');
    resolverMock.verify('inspect', 0);
  }

  @IsTest
  static void append_claimOnOwnFile_storesTheVersionIdAndFileSize() {
    useMocks(new List<Database.SaveResult>{ EventIngestionTestFactory.savedResult(null) }, null);
    ContentVersion version = EventIngestionTestFactory.version(processor().Id, 5000000, null);
    String shortRef = String.valueOf(version.Id).left(15);
    useClaims(new Map<String, PayloadClaim>{ shortRef => PayloadClaim.found(shortRef, version) });

    List<AppendResult> results = appendAsProcessor(new List<Inbound_Message__c>{ claimed('ORD-1', shortRef) });

    Assert.isTrue(results[0].isAccepted(), 'Accepted: ' + results[0].getError());
    Inbound_Message__c row = insertedRows()[0];
    Assert.areEqual(version.Id, row.Payload_Ref__c, 'Normalised to the 18-character version Id');
    Assert.areEqual(5000000, row.Payload_Size__c, 'The file size, for the dispatch budget');
    Assert.isNull(row.Payload__c, 'Nothing inline');
    Assert.areEqual(new Set<String>{ shortRef }, resolverMock.argumentsOf('inspect', 0)[0], 'Inspected as sent');
  }

  @IsTest
  static void append_inlineAndClaimTogether_rejectsWithTheKey() {
    useMocks(null, null);
    Inbound_Message__c both = claimed('ORD-1', FakeId.generate(ContentVersion.SObjectType));
    both.Payload__c = '{}';

    List<AppendResult> results = appendAsProcessor(new List<Inbound_Message__c>{ both });

    Assert.isTrue(results[0].isRejected() && results[0].getError().contains('not both'), results[0].getError());
    Assert.areEqual('erp:ORD-1', results[0].getIdempotencyKey(), 'Rejected by key, for the intake log');
    resolverMock.verify('inspect', 0);
    dmlMock.verify('insertPartial', 0);
  }

  @IsTest
  static void append_claimsChecksEachAgainstItsOwnProducer() {
    useMocks(new List<Database.SaveResult>{ EventIngestionTestFactory.savedResult(null) }, null);
    Id uploader = FakeId.generate(User.SObjectType);
    Id someoneElse = FakeId.generate(User.SObjectType);
    ContentVersion version = EventIngestionTestFactory.version(uploader, 10, null);
    useClaims(new Map<String, PayloadClaim>{ version.Id => PayloadClaim.found(version.Id, version) });
    List<Inbound_Message__c> messages = new List<Inbound_Message__c>{
      claimed('ORD-1', version.Id),
      claimed('ORD-2', version.Id)
    };

    List<AppendResult> results = appendAsProcessor(messages, new List<Id>{ someoneElse, uploader });

    Assert.isTrue(results[0].isRejected(), 'Another producer cannot claim the file');
    Assert.isTrue(results[0].getError().contains('was not uploaded by the producer'), results[0].getError());
    Assert.isTrue(results[1].isAccepted(), 'The uploader can');
    Assert.areEqual(1, insertedRows().size(), 'Only the valid claim is inserted');
    Assert.areEqual('ORD-2', insertedRows()[0].External_Message_Id__c, 'The kept row is the uploader\'s message');
  }

  @IsTest
  static void append_claimWithoutProducers_checksTheRunningUser() {
    useMocks(null, null);
    ContentVersion version = EventIngestionTestFactory.version(FakeId.generate(User.SObjectType), 10, null);
    useClaims(new Map<String, PayloadClaim>{ version.Id => PayloadClaim.found(version.Id, version) });

    List<AppendResult> results = appendAsProcessor(new List<Inbound_Message__c>{ claimed('ORD-1', version.Id) });

    Assert.isTrue(results[0].isRejected(), 'The caller did not upload it');
    dmlMock.verify('insertPartial', 0);
  }

  @IsTest
  static void append_unusableClaim_rejectsWithItsReason() {
    useMocks(null, null);
    String ref = FakeId.generate(ContentVersion.SObjectType);
    useClaims(new Map<String, PayloadClaim>{ ref => PayloadClaim.unusable(ref, 'Too big.') });

    List<AppendResult> results = appendAsProcessor(new List<Inbound_Message__c>{ claimed('ORD-1', ref) });

    Assert.areEqual('Too big.', results[0].getError(), 'The resolver\'s reason');
  }

  @IsTest
  static void append_producerListOfTheWrongSize_throws() {
    useMocks(null, null);
    try {
      appendAsProcessor(EventIngestionTestFactory.messages(2), new List<Id>{ UserInfo.getUserId() });
      Assert.fail('Expected IllegalArgumentException');
    } catch (IllegalArgumentException e) {
      Assert.isTrue(e.getMessage().contains('one producer Id per message'), e.getMessage());
    }
  }

  @IsTest
  static void append_200Claims_inspectsOnce() {
    List<Database.SaveResult> saves = new List<Database.SaveResult>();
    Map<String, PayloadClaim> claims = new Map<String, PayloadClaim>();
    List<Inbound_Message__c> messages = new List<Inbound_Message__c>();
    for (Integer i = 0; i < 200; i++) {
      ContentVersion version = EventIngestionTestFactory.version(processor().Id, 10, null);
      claims.put(version.Id, PayloadClaim.found(version.Id, version));
      messages.add(claimed('ORD-' + i, version.Id));
      saves.add(EventIngestionTestFactory.savedResult(null));
    }
    useMocks(saves, null);
    useClaims(claims);

    processor(); // setup DML and queries stay outside the measured block
    Test.startTest();
    List<AppendResult> results = appendAsProcessor(messages);
    Test.stopTest();

    resolverMock.verify('inspect', 1);
    Assert.areEqual(200, insertedRows().size(), 'Every claim inserted in one statement');
    Assert.isTrue(results[199].isAccepted(), 'Accepted');
  }
}
