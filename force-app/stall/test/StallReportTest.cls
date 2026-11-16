/**
 * @description Tests for the `StallReport` DTO.
 *
 * Subject:  StallReport
 * Mocks:    none (a value object)
 * Bulk:     the 200 cap
 * Negative: null lists; a caller changing the list it passed or got back
 */
@IsTest
private class StallReportTest {
  private static final Datetime BEFORE = Datetime.newInstanceGmt(2026, 11, 16, 11, 30, 0);

  private static List<Id> ids(Integer count) {
    List<Id> result = new List<Id>();
    for (Integer i = 0; i < count; i++) {
      result.add(FakeId.generate(Inbound_Message__c.SObjectType));
    }
    return result;
  }

  @IsTest
  static void constructor_nullLists_reportsNothingDue() {
    StallReport report = new StallReport(BEFORE, null, null);

    Assert.isFalse(report.hasDueMessages(), 'Nothing due');
    Assert.areEqual(new List<Id>(), report.getStalledIds(), 'No stalled messages');
    Assert.isFalse(report.isCapped(), 'Not capped');
    Assert.areEqual(BEFORE, report.getStalledBefore(), 'Threshold kept');
  }

  @IsTest
  static void constructor_dueButNotStalled_reportsDue() {
    StallReport report = new StallReport(BEFORE, new List<Id>(), ids(1));

    Assert.isTrue(report.hasDueMessages(), 'Due');
    Assert.isTrue(report.getStalledIds().isEmpty(), 'Not stalled');
  }

  @IsTest
  static void constructor_stalled_isDueAndCappedOnlyAtTheMaximum() {
    Assert.isTrue(new StallReport(BEFORE, ids(1), null).hasDueMessages(), 'A stalled message is due');
    Assert.isFalse(new StallReport(BEFORE, ids(199), null).isCapped(), 'Under the cap');
    Assert.isTrue(new StallReport(BEFORE, ids(StallReport.MAX_STALLED), null).isCapped(), 'At the cap');
  }

  @IsTest
  static void getStalledIds_callerChangesALIst_doesNotChangeTheReport() {
    List<Id> stalled = ids(2);
    StallReport report = new StallReport(BEFORE, stalled, null);

    stalled.clear();
    report.getStalledIds().clear();

    Assert.areEqual(2, report.getStalledIds().size(), 'Immutable');
  }
}
