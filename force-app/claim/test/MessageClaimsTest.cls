/**
 * @description Unit tests for `MessageClaims`, with a Stub API mock of `IPayloadResolver`.
 *
 * Subject:  MessageClaims.check
 * Mocks:    IPayloadResolver
 * Bulk:     covered through MessageStoreTest (200 claims → 1 inspect)
 * Negative: no claims (no inspect), a claim the resolver didn't answer for, another uploader
 */
@IsTest
private class MessageClaimsTest {
  private static final Id PRODUCER = FakeId.generate(User.SObjectType);

  private static Mocks useClaims(Map<String, PayloadClaim> claims) {
    Mocks resolverMock = new Mocks().stubReturn('inspect', claims);
    Application.Service.setMock(IPayloadResolver.class, resolverMock.stub(IPayloadResolver.class));
    return resolverMock;
  }

  private static Inbound_Message__c row(String ref) {
    return new Inbound_Message__c(Payload_Ref__c = ref, Payload__c = ref == null ? '{}' : null);
  }

  @IsTest
  static void check_inlineRowsOnly_findsNoProblemWithoutInspecting() {
    Mocks resolverMock = useClaims(new Map<String, PayloadClaim>());

    Map<Integer, String> problems = MessageClaims.check(
      new List<Inbound_Message__c>{ row(null), row(' ') },
      new List<Id>{ PRODUCER, PRODUCER }
    );

    Assert.areEqual(0, problems.size(), 'Inline rows are fine');
    resolverMock.verify('inspect', 0);
  }

  @IsTest
  static void check_mixedRows_judgesOnlyTheClaims() {
    ContentVersion version = EventIngestionTestFactory.version(PRODUCER, 123, null);
    String uninspected = FakeId.generate(ContentVersion.SObjectType);
    useClaims(new Map<String, PayloadClaim>{ version.Id => PayloadClaim.found(version.Id, version) });
    List<Inbound_Message__c> rows = new List<Inbound_Message__c>{ row(null), row(version.Id), row(uninspected) };

    Map<Integer, String> problems = MessageClaims.check(rows, new List<Id>{ PRODUCER, PRODUCER, PRODUCER });

    Assert.areEqual(new Set<Integer>{ 2 }, problems.keySet(), 'Only the claim nobody answered for');
    Assert.isTrue(problems.get(2).contains('was not inspected'), problems.get(2));
    Assert.areEqual(123, rows[1].Payload_Size__c, 'The usable claim gets the file size');
    Assert.isNull(rows[0].Payload_Size__c, 'The inline row is left alone');
  }

  @IsTest
  static void check_claimOnAnotherUploadersFile_isAProblemAndLeftUnchanged() {
    ContentVersion version = EventIngestionTestFactory.version(FakeId.generate(User.SObjectType), 5, null);
    useClaims(new Map<String, PayloadClaim>{ version.Id => PayloadClaim.found(version.Id, version) });
    List<Inbound_Message__c> rows = new List<Inbound_Message__c>{ row(version.Id) };

    Map<Integer, String> problems = MessageClaims.check(rows, new List<Id>{ PRODUCER });

    Assert.isTrue(problems.get(0).contains('was not uploaded by the producer'), problems.get(0));
    Assert.isNull(rows[0].Payload_Size__c, 'Not normalised');
  }
}
