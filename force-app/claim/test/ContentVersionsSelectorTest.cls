/**
 * @description Integration tests for `ContentVersionsSelector` against real files, in user mode.
 *
 * Subject:  ContentVersionsSelector.selectByIds, selectWithDataByIds
 * Mocks:    none (real ContentVersion inserts)
 * Bulk:     not applicable (claims are inspected through one query per append; see the resolver test)
 * Negative: empty input queries nothing; a Minimum Access user can't see another user's file
 */
@IsTest
private class ContentVersionsSelectorTest {
  @IsTest
  static void selectByIds_ownFile_returnsSizeAndUploaderWithoutData() {
    Id versionId = EventIngestionTestFactory.claimFile('{"a":1}');

    List<ContentVersion> versions = new ContentVersionsSelector().selectByIds(new Set<Id>{ versionId });

    Assert.areEqual(1, versions.size(), 'Found');
    Assert.areEqual(7, versions[0].ContentSize, 'Size in bytes');
    Assert.areEqual(UserInfo.getUserId(), versions[0].CreatedById, 'Uploaded by the running user');
    try {
      Blob data = versions[0].VersionData;
      Assert.fail('VersionData was queried: ' + data);
    } catch (SObjectException e) {
      Assert.isTrue(e.getMessage().contains('VersionData'), e.getMessage());
    }
  }

  @IsTest
  static void selectWithDataByIds_ownFile_returnsTheData() {
    Id versionId = EventIngestionTestFactory.claimFile('{"a":1}');

    List<ContentVersion> versions = new ContentVersionsSelector().selectWithDataByIds(new Set<Id>{ versionId });

    Assert.areEqual('{"a":1}', versions[0].VersionData.toString(), 'The file data');
  }

  @IsTest
  static void select_emptyIds_queriesNothing() {
    ContentVersionsSelector selector = new ContentVersionsSelector();

    Integer before = Limits.getQueries();
    Assert.areEqual(0, selector.selectByIds(new Set<Id>()).size(), 'Empty');
    Assert.areEqual(0, selector.selectWithDataByIds(null).size(), 'Null');
    Assert.areEqual(before, Limits.getQueries(), 'No SOQL');
  }

  @IsTest
  static void selectByIds_anotherUsersFile_isInvisibleToAMinimumAccessUser() {
    Id versionId = EventIngestionTestFactory.claimFile('{"secret":true}');
    User other = EventIngestionTestFactory.minimumAccessUser(null);

    System.runAs(other) {
      Assert.areEqual(
        0,
        new ContentVersionsSelector().selectByIds(new Set<Id>{ versionId }).size(),
        'User mode: an unshared file is not visible'
      );
    }
  }
}
