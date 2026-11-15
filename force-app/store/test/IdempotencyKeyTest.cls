/**
 * @description Tests for `IdempotencyKey`.
 *
 * Subject:  IdempotencyKey.of
 * Mocks:    none (pure)
 * Bulk:     n/a (one key per call)
 * Negative: blank source, blank Id, `:` in the source
 */
@IsTest
private class IdempotencyKeyTest {
  /** Returns the rejection message, or fails the test if a key was built. */
  private static String rejection(String source, String externalMessageId) {
    try {
      IdempotencyKey.of(source, externalMessageId);
    } catch (IllegalArgumentException e) {
      return e.getMessage();
    }
    Assert.fail('Expected IllegalArgumentException for "' + source + '" / "' + externalMessageId + '"');
    return null;
  }

  @IsTest
  static void of_sourceAndId_joinsThemWithAColon() {
    Assert.areEqual('erp:ORD-1', IdempotencyKey.of('erp', 'ORD-1'), 'Source, separator, Id');
  }

  @IsTest
  static void of_idContainingColons_keepsThem() {
    Assert.areEqual('erp:a:b:c', IdempotencyKey.of('erp', 'a:b:c'), 'Only the source is restricted');
  }

  @IsTest
  static void of_mixedCaseAndSpaces_keepsThemExactly() {
    Assert.areEqual('ERP:Ord 1 ', IdempotencyKey.of('ERP', 'Ord 1 '), 'The key is case-sensitive and not trimmed');
  }

  @IsTest
  static void of_blankSource_throws() {
    Assert.isTrue(rejection(null, 'ORD-1').contains('Source__c'), 'Names the problem: Source__c');
    Assert.isTrue(rejection('  ', 'ORD-1').contains('Source__c'), 'Names the problem: Source__c');
  }

  @IsTest
  static void of_blankExternalId_throws() {
    Assert.isTrue(
      rejection('erp', null).contains('External_Message_Id__c'),
      'Names the problem: External_Message_Id__c'
    );
    Assert.isTrue(rejection('erp', '').contains('External_Message_Id__c'), 'Names the problem: External_Message_Id__c');
  }

  @IsTest
  static void of_sourceContainingTheSeparator_throws() {
    Assert.isTrue(rejection('erp:eu', 'ORD-1').contains('ambiguous'), 'Names the problem: ambiguous');
  }
}
