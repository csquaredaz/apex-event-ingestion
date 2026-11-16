/**
 * @description Tests for `StallSweeperSchedulable`: the four schedules and the sweep it delegates.
 *
 * Subject:  StallSweeperSchedulable.execute, scheduleEveryQuarterHour
 * Mocks:    IStallDetector
 * Bulk:     not applicable (four jobs, one sweep)
 * Negative: scheduling twice throws and leaves the first four in place
 */
@IsTest
private class StallSweeperSchedulableTest {
  @IsTest
  static void execute_scheduledRun_sweepsOnceThroughTheBoundDetector() {
    Mocks detectorMock = new Mocks().stubReturn('sweep', new StallReport(Datetime.now(), null, null));
    Application.Service.setMock(IStallDetector.class, detectorMock.stub(IStallDetector.class));

    Test.startTest();
    System.schedule('aei stall sweeper test', StallSweeperSchedulable.cronAt(0), new StallSweeperSchedulable());
    Test.stopTest();

    detectorMock.verify('sweep', 1);
    Assert.isNotNull(detectorMock.argumentsOf('sweep', 0)[0], 'Swept at the current time');
  }

  @IsTest
  static void scheduleEveryQuarterHour_once_schedulesFourNamedJobs() {
    Test.startTest();
    List<Id> jobIds = StallSweeperSchedulable.scheduleEveryQuarterHour();
    Test.stopTest();

    Assert.areEqual(4, jobIds.size(), 'One per quarter hour');
    Map<String, String> cronByName = new Map<String, String>();
    for (CronTrigger job : [
      SELECT CronExpression, CronJobDetail.Name
      FROM CronTrigger
      WHERE Id IN :jobIds
      WITH SYSTEM_MODE
    ]) {
      cronByName.put(job.CronJobDetail.Name, job.CronExpression);
    }
    Assert.areEqual(
      new Map<String, String>{
        'aei stall sweeper :00' => '0 0 * * * ?',
        'aei stall sweeper :15' => '0 15 * * * ?',
        'aei stall sweeper :30' => '0 30 * * * ?',
        'aei stall sweeper :45' => '0 45 * * * ?'
      },
      cronByName,
      'Names and expressions'
    );
  }

  @IsTest
  static void scheduleEveryQuarterHour_alreadyScheduled_throwsAsyncException() {
    StallSweeperSchedulable.scheduleEveryQuarterHour();

    try {
      StallSweeperSchedulable.scheduleEveryQuarterHour();
      Assert.fail('Expected AsyncException');
    } catch (AsyncException e) {
      Assert.isTrue(e.getMessage().contains('aei stall sweeper :00'), e.getMessage());
    }
    Assert.areEqual(
      4,
      [SELECT COUNT() FROM CronTrigger WHERE CronJobDetail.Name LIKE 'aei stall sweeper :%' WITH SYSTEM_MODE],
      'The first four are untouched'
    );
  }
}
