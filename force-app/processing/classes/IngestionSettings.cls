/**
 * @description The processor's and the intake trigger's limits, read from the
 * `Ingestion_Setting__mdt` row named `Default` (ADR 0006, 0007). A missing row or a blank field
 * uses the code default; a batch size above 200 is capped at 200, so a dispatch batch stays
 * bulk-safe, and an intake batch size above 2,000 is capped at 2,000, the most a Platform Event
 * trigger receives. `getInstance` reads the metadata
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

  /** @description Events one intake trigger run stores when the setting is blank. */
  public static final Integer DEFAULT_INTAKE_BATCH_SIZE = 200;
  /** @description Payload characters one intake trigger run takes when the setting is blank. */
  public static final Integer DEFAULT_INTAKE_PAYLOAD_BUDGET = 3000000;

  private static final Integer MAX_BATCH_SIZE = 200;
  private static final Integer MAX_INTAKE_BATCH_SIZE = 2000;

  // Tests replace the row; custom metadata can't be inserted in a test.
  @TestVisible
  private static Ingestion_Setting__mdt row = Ingestion_Setting__mdt.getInstance(DEFAULT_ROW);

  private final Integer batchSize;
  private final RetrySchedule retrySchedule;
  private final Integer intakeBatchSize;
  private final Integer intakePayloadBudget;

  private IngestionSettings(Ingestion_Setting__mdt setting) {
    Ingestion_Setting__mdt values = setting == null ? new Ingestion_Setting__mdt() : setting;
    batchSize = Math.min(valueOr(values.Batch_Size__c, DEFAULT_BATCH_SIZE), MAX_BATCH_SIZE);
    retrySchedule = new RetrySchedule(
      valueOr(values.Max_Attempts__c, DEFAULT_MAX_ATTEMPTS),
      valueOr(values.Base_Delay_Minutes__c, DEFAULT_BASE_DELAY_MINUTES),
      valueOr(values.Max_Delay_Minutes__c, DEFAULT_MAX_DELAY_MINUTES)
    );
    intakeBatchSize = Math.min(valueOr(values.Intake_Batch_Size__c, DEFAULT_INTAKE_BATCH_SIZE), MAX_INTAKE_BATCH_SIZE);
    intakePayloadBudget = valueOr(values.Intake_Payload_Budget__c, DEFAULT_INTAKE_PAYLOAD_BUDGET);
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

  /** @description @return Events one intake trigger run stores before a resume checkpoint, from 1 to 2,000. */
  public Integer getIntakeBatchSize() {
    return intakeBatchSize;
  }

  /**
   * @description Payload characters one intake trigger run takes before a resume checkpoint. The
   * first event is always taken, however large, so one big payload can't stall the stream.
   * @return The budget, at least 1.
   */
  public Integer getIntakePayloadBudget() {
    return intakePayloadBudget;
  }

  /** A blank or non-positive field uses the default. */
  private static Integer valueOr(Decimal value, Integer fallback) {
    return value == null || value < 1 ? fallback : value.intValue();
  }
}
