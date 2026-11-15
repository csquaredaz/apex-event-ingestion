/**
 * @description Tests for `RetrySchedule`: the doubling backoff, its cap and the attempt limit.
 *
 * Subject:  RetrySchedule.nextAttemptAt, RetrySchedule.isExhausted
 * Mocks:    none (pure value object)
 * Bulk:     not applicable (no collections)
 * Negative: impossible limits, attempts below 1, a null time, a huge attempt count
 */
@IsTest
private class RetryScheduleTest {
  private static final Datetime NOW = Datetime.newInstanceGmt(2026, 11, 15, 12, 0, 0);

  @IsTest
  static void nextAttemptAt_attempts1To4_doublesFromTheBaseDelay() {
    RetrySchedule schedule = new RetrySchedule(5, 1, 60);

    Assert.areEqual(NOW.addMinutes(1), schedule.nextAttemptAt(1, NOW), 'After the first attempt: the base');
    Assert.areEqual(NOW.addMinutes(2), schedule.nextAttemptAt(2, NOW), 'Doubled');
    Assert.areEqual(NOW.addMinutes(4), schedule.nextAttemptAt(3, NOW), 'Doubled again');
    Assert.areEqual(NOW.addMinutes(8), schedule.nextAttemptAt(4, NOW), 'And again');
  }

  @IsTest
  static void nextAttemptAt_pastTheCap_waitsTheMaximumDelay() {
    RetrySchedule schedule = new RetrySchedule(100, 5, 30);

    Assert.areEqual(NOW.addMinutes(20), schedule.nextAttemptAt(3, NOW), '5, 10, 20');
    Assert.areEqual(NOW.addMinutes(30), schedule.nextAttemptAt(4, NOW), '40 is capped at 30');
    Assert.areEqual(NOW.addMinutes(30), schedule.nextAttemptAt(99, NOW), 'No overflow on a large count');
  }

  @IsTest
  static void isExhausted_atAndBelowTheMaximum_isTrueOnlyAtTheMaximum() {
    RetrySchedule schedule = new RetrySchedule(3, 1, 60);

    Assert.isFalse(schedule.isExhausted(2), 'One attempt left');
    Assert.isTrue(schedule.isExhausted(3), 'Out of attempts');
    Assert.isTrue(schedule.isExhausted(4), 'Past the maximum');
    Assert.isFalse(schedule.isExhausted(null), 'Unknown is not exhausted');
  }

  @IsTest
  static void constructor_impossibleLimits_throwsIllegalArgumentException() {
    List<List<Integer>> invalid = new List<List<Integer>>{
      new List<Integer>{ 0, 1, 60 },
      new List<Integer>{ 5, 0, 60 },
      new List<Integer>{ 5, 10, 5 },
      new List<Integer>{ null, 1, 60 }
    };
    Integer rejected = 0;
    for (List<Integer> limits : invalid) {
      try {
        new RetrySchedule(limits[0], limits[1], limits[2]);
      } catch (IllegalArgumentException e) {
        rejected++;
      }
    }
    Assert.areEqual(invalid.size(), rejected, 'Every impossible combination is rejected');
  }

  @IsTest
  static void nextAttemptAt_noAttemptOrNoTime_throwsIllegalArgumentException() {
    RetrySchedule schedule = new RetrySchedule(5, 1, 60);
    try {
      schedule.nextAttemptAt(0, NOW);
      Assert.fail('Expected IllegalArgumentException for attempt 0');
    } catch (IllegalArgumentException e) {
      Assert.isTrue(e.getMessage().contains('attemptsMade'), e.getMessage());
    }
    try {
      schedule.nextAttemptAt(1, null);
      Assert.fail('Expected IllegalArgumentException for a null time');
    } catch (IllegalArgumentException e) {
      Assert.isTrue(e.getMessage().contains('time'), e.getMessage());
    }
  }
}
