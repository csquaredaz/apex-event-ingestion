/**
 * @description The processor's limits, read from the `Ingestion_Setting__mdt` row named
 * `Default` (ADR 0006). A missing row or a blank field uses the code default; a batch size above
 * 200 is capped at 200, so a dispatch batch stays bulk-safe. `getInstance` reads the metadata
 * cache: no SOQL and no object permission, so the Automated Process user can read it. Immutable.
 * @group Processing
 */
public with sharing class IngestionSettings {
  /** @description The row the package reads. */
  public static final String DEFAULT_ROW = 'Default';
  /** @description Messages per job when the setting is blank. */
  public static final Integer DEFAULT_BATCH_SIZE = 200;
  /** @description Attempts before `Dead` when the setting is blank. */
  public static final Integer DEFAULT_MAX_ATTEMPTS = 5;
  /** @description First backoff, in minutes, when the setting is blank. */
  public static final Integer DEFAULT_BASE_DELAY_MINUTES = 1;
  /** @description Longest backoff, in minutes, when the setting is blank. */
  public static final Integer DEFAULT_MAX_DELAY_MINUTES = 60;

  private static final Integer MAX_BATCH_SIZE = 200;

  // Tests replace the row; custom metadata can't be inserted in a test.
  @TestVisible
  private static Ingestion_Setting__mdt row = Ingestion_Setting__mdt.getInstance(DEFAULT_ROW);

  private final Integer batchSize;
  private final RetrySchedule retrySchedule;

  private IngestionSettings(Ingestion_Setting__mdt setting) {
    Ingestion_Setting__mdt values = setting == null ? new Ingestion_Setting__mdt() : setting;
    batchSize = Math.min(valueOr(values.Batch_Size__c, DEFAULT_BATCH_SIZE), MAX_BATCH_SIZE);
    retrySchedule = new RetrySchedule(
      valueOr(values.Max_Attempts__c, DEFAULT_MAX_ATTEMPTS),
      valueOr(values.Base_Delay_Minutes__c, DEFAULT_BASE_DELAY_MINUTES),
      valueOr(values.Max_Delay_Minutes__c, DEFAULT_MAX_DELAY_MINUTES)
    );
  }

  /**
   * @description The settings in force now.
   * @return The `Default` row's values, or the code defaults.
   * @throws IllegalArgumentException If the row holds an impossible combination, such as a
   * maximum delay below the base delay.
   */
  public static IngestionSettings current() {
    return new IngestionSettings(row);
  }

  /** @description @return Messages one processor job claims, from 1 to 200. */
  public Integer getBatchSize() {
    return batchSize;
  }

  /** @description @return The backoff and attempt limit. */
  public RetrySchedule getRetrySchedule() {
    return retrySchedule;
  }

  /** A blank or non-positive field uses the default. */
  private static Integer valueOr(Decimal value, Integer fallback) {
    return value == null || value < 1 ? fallback : value.intValue();
  }
}
