/**
 * @description Unit tests for `ContentVersionPayloadResolver`, with a Stub API mock of
 * `IContentVersionsSelector` returning in-memory versions, so no file is read.
 *
 * Subject:  ContentVersionPayloadResolver.inspect, resolve
 * Mocks:    IContentVersionsSelector
 * Bulk:     200 refs → 1 selector call each for inspect and resolve
 * Negative: null/empty refs, text that isn't an Id, another object's Id, an invisible version,
 *           a version over Claim_Max_Bytes__c, data that isn't UTF-8
 */
@IsTest
private class ContentVersionPayloadResolverTest {
  private static final Id UPLOADER = FakeId.generate(User.SObjectType);
  private static Mocks selectorMock;

  private static void useVersions(List<ContentVersion> versions) {
    selectorMock = new Mocks().stubReturn('selectByIds', versions).stubReturn('selectWithDataByIds', versions);
    Application.Selector.setMock(
      ContentVersion.SObjectType,
      (ISelector) selectorMock.stub(IContentVersionsSelector.class)
    );
  }

  @IsTest
  static void bindings_resolveTheDefaults() {
    Assert.isInstanceOfType(
      Application.Service.newInstance(IPayloadResolver.class),
      ContentVersionPayloadResolver.class,
      'DI_Binding.Payload_Resolver'
    );
    Assert.isInstanceOfType(
      Application.Selector.newInstance(ContentVersion.SObjectType),
      ContentVersionsSelector.class,
      'DI_Binding.Content_Versions_Selector'
    );
  }

  @IsTest
  static void inspectAndResolve_nullOrEmpty_returnNothingWithoutQuerying() {
    useVersions(new List<ContentVersion>());
    ContentVersionPayloadResolver resolver = new ContentVersionPayloadResolver();

    Assert.areEqual(0, resolver.inspect(null).size(), 'Null inspect');
    Assert.areEqual(0, resolver.inspect(new Set<String>()).size(), 'Empty inspect');
    Assert.areEqual(0, resolver.resolve(null).size(), 'Null resolve');
    selectorMock.verify('selectByIds', 0);
    selectorMock.verify('selectWithDataByIds', 0);
  }

  @IsTest
  static void inspect_mixedRefs_judgesEachAndQueriesOnlyVersionIds() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Claim_Max_Bytes__c = 100);
    ContentVersion fits = EventIngestionTestFactory.version(UPLOADER, 100, null);
    ContentVersion tooBig = EventIngestionTestFactory.version(UPLOADER, 101, null);
    String invisible = FakeId.generate(ContentVersion.SObjectType);
    String account = FakeId.generate(Account.SObjectType);
    useVersions(new List<ContentVersion>{ fits, tooBig });

    Map<String, PayloadClaim> claims = new ContentVersionPayloadResolver()
      .inspect(new Set<String>{ fits.Id, tooBig.Id, invisible, account, 'not-an-id' });

    Assert.areEqual(5, claims.size(), 'One claim per ref');
    Assert.isNull(claims.get(fits.Id).getError(), 'At the cap is fine');
    Assert.areEqual(UPLOADER, claims.get(fits.Id).getUploadedById(), 'Uploader carried');
    Assert.isTrue(claims.get(tooBig.Id).getError().contains('Claim_Max_Bytes__c allows 100'), 'Over the cap');
    Assert.isTrue(claims.get(invisible).getError().contains('is visible'), claims.get(invisible).getError());
    Assert.isTrue(claims.get(account).getError().contains('not a ContentVersion Id'), 'Another object');
    Assert.isTrue(claims.get('not-an-id').getError().contains('not a ContentVersion Id'), 'Not an Id');
    Assert.areEqual(
      new Set<Id>{ fits.Id, tooBig.Id, invisible },
      (Set<Id>) selectorMock.argumentsOf('selectByIds', 0)[0],
      'Queries only the version Ids'
    );
  }

  @IsTest
  static void inspect_15CharacterRef_normalisesToTheVersionId() {
    ContentVersion version = EventIngestionTestFactory.version(UPLOADER, 1, null);
    useVersions(new List<ContentVersion>{ version });
    String shortRef = String.valueOf(version.Id).left(15);

    PayloadClaim claim = new ContentVersionPayloadResolver().inspect(new Set<String>{ shortRef }).get(shortRef);

    Assert.areEqual(version.Id, claim.getVersionId(), 'The 18-character Id the store keeps');
  }

  @IsTest
  static void inspect_200Refs_queriesOnce() {
    List<ContentVersion> versions = new List<ContentVersion>();
    Set<String> refs = new Set<String>();
    for (Integer i = 0; i < 200; i++) {
      ContentVersion version = EventIngestionTestFactory.version(UPLOADER, 10, null);
      versions.add(version);
      refs.add(version.Id);
    }
    useVersions(versions);

    Test.startTest();
    Map<String, PayloadClaim> claims = new ContentVersionPayloadResolver().inspect(refs);
    Test.stopTest();

    Assert.areEqual(200, claims.size(), 'All judged');
    selectorMock.verify('selectByIds', 1);
  }

  @IsTest
  static void resolve_versions_returnsTheirTextAndLeavesOutTheRest() {
    ContentVersion json = EventIngestionTestFactory.version(UPLOADER, 13, Blob.valueOf('{"big":"yes"}'));
    ContentVersion notUtf8 = EventIngestionTestFactory.version(UPLOADER, 1, EncodingUtil.base64Decode('/w=='));
    String missing = FakeId.generate(ContentVersion.SObjectType);
    useVersions(new List<ContentVersion>{ json, notUtf8 });

    Map<String, String> payloads = new ContentVersionPayloadResolver()
      .resolve(new Set<String>{ json.Id, notUtf8.Id, missing, 'not-an-id' });

    Assert.areEqual(new Set<String>{ json.Id }, payloads.keySet(), 'Only the readable UTF-8 file');
    Assert.areEqual('{"big":"yes"}', payloads.get(json.Id), 'Its text');
    Assert.isNull(json.VersionData, 'The file data is released once converted');
    selectorMock.verify('selectWithDataByIds', 1);
  }

  @IsTest
  static void inspectAndResolve_blankRefOrVersionWithoutData_areUnusable() {
    ContentVersion empty = EventIngestionTestFactory.version(UPLOADER, 0, null);
    useVersions(new List<ContentVersion>{ empty });
    ContentVersionPayloadResolver resolver = new ContentVersionPayloadResolver();

    PayloadClaim blank = resolver.inspect(new Set<String>{ ' ' }).get(' ');
    Map<String, String> payloads = resolver.resolve(new Set<String>{ empty.Id });

    Assert.isTrue(blank.getError().contains('not a ContentVersion Id'), blank.getError());
    Assert.isFalse(payloads.containsKey(empty.Id), 'No data, nothing to hand a handler');
  }
}
