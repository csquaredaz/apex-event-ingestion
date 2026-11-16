/**
 * @description Tests for `IngestionSettings`: the shipped `Default` row, code defaults for a
 * missing row or blank fields, and the batch cap. Rows are replaced through the `@TestVisible`
 * seam, because custom metadata can't be inserted in a test.
 *
 * Subject:  IngestionSettings.current
 * Mocks:    the Ingestion_Setting__mdt row (in memory)
 * Bulk:     not applicable (one settings row)
 * Negative: no row, blank and zero fields, a batch size above 200, an intake batch above 2,000,
 *           a max delay below the base
 */
@IsTest
private class IngestionSettingsTest {
  private static final Datetime NOW = Datetime.newInstanceGmt(2026, 11, 15, 12, 0, 0);

  @IsTest
  static void current_shippedDefaultRow_usesItsValues() {
    IngestionSettings settings = IngestionSettings.current();

    Assert.areEqual(200, settings.getBatchSize(), 'Ingestion_Setting.Default batch size');
    Assert.isTrue(settings.getRetrySchedule().isExhausted(5), 'Five attempts');
    Assert.isFalse(settings.getRetrySchedule().isExhausted(4), 'Not four');
    Assert.areEqual(NOW.addMinutes(60), settings.getRetrySchedule().nextAttemptAt(10, NOW), 'Capped at 60');
    Assert.areEqual(200, settings.getIntakeBatchSize(), 'Ingestion_Setting.Default intake batch');
    Assert.areEqual(3000000, settings.getIntakePayloadBudget(), 'Ingestion_Setting.Default payload budget');
    Assert.areEqual(3000000, settings.getClaimMaxBytes(), 'Ingestion_Setting.Default claim cap');
    Assert.areEqual(4000000, settings.getDispatchPayloadBudget(), 'Ingestion_Setting.Default dispatch budget');
    Assert.areEqual(30, settings.getStallAfterMinutes(), 'Ingestion_Setting.Default stall threshold');
  }

  @IsTest
  static void current_rowWithValues_usesThem() {
    IngestionSettings.row = new Ingestion_Setting__mdt(
      Batch_Size__c = 50,
      Max_Attempts__c = 3,
      Base_Delay_Minutes__c = 2,
      Max_Delay_Minutes__c = 5
    );

    IngestionSettings settings = IngestionSettings.current();

    Assert.areEqual(50, settings.getBatchSize(), 'Batch size from the row');
    Assert.isTrue(settings.getRetrySchedule().isExhausted(3), 'Max attempts from the row');
    Assert.areEqual(NOW.addMinutes(2), settings.getRetrySchedule().nextAttemptAt(1, NOW), 'Base from the row');
    Assert.areEqual(NOW.addMinutes(5), settings.getRetrySchedule().nextAttemptAt(3, NOW), 'Cap from the row');
  }

  @IsTest
  static void current_noRowOrBlankFields_usesTheCodeDefaults() {
    IngestionSettings.row = null;
    IngestionSettings missing = IngestionSettings.current();
    IngestionSettings.row = new Ingestion_Setting__mdt(Batch_Size__c = 0, Max_Attempts__c = null);
    IngestionSettings blank = IngestionSettings.current();

    for (IngestionSettings settings : new List<IngestionSettings>{ missing, blank }) {
      Assert.areEqual(IngestionSettings.DEFAULT_BATCH_SIZE, settings.getBatchSize(), 'Default batch size');
      Assert.isTrue(settings.getRetrySchedule().isExhausted(IngestionSettings.DEFAULT_MAX_ATTEMPTS), 'Default max');
      Assert.areEqual(
        NOW.addMinutes(IngestionSettings.DEFAULT_BASE_DELAY_MINUTES),
        settings.getRetrySchedule().nextAttemptAt(1, NOW),
        'Default base delay'
      );
    }
  }

  @IsTest
  static void current_batchSizeAbove200_isCappedAt200() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Batch_Size__c = 2000);

    Assert.areEqual(200, IngestionSettings.current().getBatchSize(), 'A dispatch batch stays bulk-safe');
  }

  @IsTest
  static void current_maxDelayBelowBase_throwsIllegalArgumentException() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Base_Delay_Minutes__c = 30, Max_Delay_Minutes__c = 10);
    try {
      IngestionSettings.current();
      Assert.fail('Expected IllegalArgumentException');
    } catch (IllegalArgumentException e) {
      Assert.isTrue(e.getMessage().contains('maxDelayMinutes'), e.getMessage());
    }
  }

  @IsTest
  static void current_intakeFields_useTheRowOrTheDefaultsAndCapTheBatchAt2000() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Intake_Batch_Size__c = 50, Intake_Payload_Budget__c = 1000);
    IngestionSettings fromRow = IngestionSettings.current();
    IngestionSettings.row = new Ingestion_Setting__mdt(Intake_Batch_Size__c = 5000, Intake_Payload_Budget__c = 0);
    IngestionSettings capped = IngestionSettings.current();

    Assert.areEqual(50, fromRow.getIntakeBatchSize(), 'Intake batch from the row');
    Assert.areEqual(1000, fromRow.getIntakePayloadBudget(), 'Budget from the row');
    Assert.areEqual(2000, capped.getIntakeBatchSize(), 'The most a Platform Event trigger receives');
    Assert.areEqual(
      IngestionSettings.DEFAULT_INTAKE_PAYLOAD_BUDGET,
      capped.getIntakePayloadBudget(),
      'Zero means default'
    );
  }

  @IsTest
  static void current_claimSettings_comeFromTheRowOrTheDefaults() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Claim_Max_Bytes__c = 1000, Dispatch_Payload_Budget__c = 5000);
    IngestionSettings fromRow = IngestionSettings.current();
    IngestionSettings.row = new Ingestion_Setting__mdt(Claim_Max_Bytes__c = 0);
    IngestionSettings blank = IngestionSettings.current();

    Assert.areEqual(1000, fromRow.getClaimMaxBytes(), 'Claim cap from the row');
    Assert.areEqual(5000, fromRow.getDispatchPayloadBudget(), 'Dispatch budget from the row');
    Assert.areEqual(
      IngestionSettings.DEFAULT_CLAIM_MAX_BYTES,
      blank.getClaimMaxBytes(),
      'Non-positive uses the default'
    );
    Assert.areEqual(
      IngestionSettings.DEFAULT_DISPATCH_PAYLOAD_BUDGET,
      blank.getDispatchPayloadBudget(),
      'Blank uses the default'
    );
  }

  @IsTest
  static void current_stallThreshold_comesFromTheRowOrTheDefault() {
    IngestionSettings.row = new Ingestion_Setting__mdt(Stall_After_Minutes__c = 90);
    IngestionSettings fromRow = IngestionSettings.current();
    IngestionSettings.row = new Ingestion_Setting__mdt(Stall_After_Minutes__c = 0);
    IngestionSettings blank = IngestionSettings.current();

    Assert.areEqual(90, fromRow.getStallAfterMinutes(), 'Stall threshold from the row');
    Assert.areEqual(IngestionSettings.DEFAULT_STALL_AFTER_MINUTES, blank.getStallAfterMinutes(), 'Default');
  }
}
