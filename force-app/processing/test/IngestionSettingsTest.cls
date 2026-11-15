/**
 * @description Tests for `IngestionSettings`: the shipped `Default` row, code defaults for a
 * missing row or blank fields, and the batch cap. Rows are replaced through the `@TestVisible`
 * seam, because custom metadata can't be inserted in a test.
 *
 * Subject:  IngestionSettings.current
 * Mocks:    the Ingestion_Setting__mdt row (in memory)
 * Bulk:     not applicable (one settings row)
 * Negative: no row, blank and zero fields, a batch size above 200, a max delay below the base
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
}
