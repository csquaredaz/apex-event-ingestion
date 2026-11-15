/**
 * @description When a retryable message is tried again, and when it has run out of attempts
 * (ADR 0006). Exponential backoff: after attempt n the next attempt waits
 * `min(maxDelay, baseDelay * 2^(n-1))` minutes. There is no jitter: processor jobs share one
 * duplicate signature, so retries don't stampede. Immutable value object.
 * @group Processing
 */
public with sharing class RetrySchedule {
  private final Integer maxAttempts;
  private final Integer baseDelayMinutes;
  private final Integer maxDelayMinutes;

  /**
   * @description Creates a schedule.
   * @param maxAttempts Attempts before a message goes `Dead`; at least 1.
   * @param baseDelayMinutes The wait after the first failed attempt; at least 1.
   * @param maxDelayMinutes The longest wait; at least `baseDelayMinutes`.
   * @throws IllegalArgumentException If a value is null or out of range.
   */
  public RetrySchedule(Integer maxAttempts, Integer baseDelayMinutes, Integer maxDelayMinutes) {
    if (
      maxAttempts == null ||
      maxAttempts < 1 ||
      baseDelayMinutes == null ||
      baseDelayMinutes < 1 ||
      maxDelayMinutes == null ||
      maxDelayMinutes < baseDelayMinutes
    ) {
      throw new IllegalArgumentException(
        'A RetrySchedule needs maxAttempts >= 1, baseDelayMinutes >= 1 and maxDelayMinutes >= baseDelayMinutes.'
      );
    }
    this.maxAttempts = maxAttempts;
    this.baseDelayMinutes = baseDelayMinutes;
    this.maxDelayMinutes = maxDelayMinutes;
  }

  /**
   * @description Whether a message that has failed this many attempts gets no more.
   * @param attemptsMade Attempts made so far, including the one that just failed.
   * @return True if `attemptsMade` has reached the maximum.
   */
  public Boolean isExhausted(Integer attemptsMade) {
    return attemptsMade != null && attemptsMade >= maxAttempts;
  }

  /**
   * @description The earliest time of the next attempt.
   * @param attemptsMade Attempts made so far, including the one that just failed; at least 1.
   * @param now The time of the failure.
   * @return `now` plus the backoff.
   * @throws IllegalArgumentException If `attemptsMade` is below 1 or `now` is null.
   */
  public Datetime nextAttemptAt(Integer attemptsMade, Datetime now) {
    if (attemptsMade == null || attemptsMade < 1 || now == null) {
      throw new IllegalArgumentException('nextAttemptAt needs attemptsMade >= 1 and a time.');
    }
    return now.addMinutes(delayMinutes(attemptsMade));
  }

  /** Doubles per attempt without overflowing: stops doubling once the cap is reached. */
  private Integer delayMinutes(Integer attemptsMade) {
    Integer delay = baseDelayMinutes;
    for (Integer attempt = 1; attempt < attemptsMade && delay < maxDelayMinutes; attempt++) {
      delay *= 2;
    }
    return Math.min(delay, maxDelayMinutes);
  }
}
