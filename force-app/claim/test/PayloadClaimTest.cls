/**
 * @description Unit tests for `PayloadClaim`, the confused-deputy guard of Claim Check (ADR 0008).
 *
 * Subject:  PayloadClaim.found, unusable, problemFor
 * Mocks:    none (in-memory ContentVersion from the factory)
 * Bulk:     not applicable (a value object)
 * Negative: a null version, an unusable claim, another uploader, an unknown producer
 */
@IsTest
private class PayloadClaimTest {
  private static final Id UPLOADER = FakeId.generate(User.SObjectType);

  @IsTest
  static void found_version_exposesItsIdSizeAndUploader() {
    ContentVersion version = EventIngestionTestFactory.version(UPLOADER, 42, null);

    PayloadClaim claim = PayloadClaim.found('ref-as-sent', version);

    Assert.areEqual('ref-as-sent', claim.getRef(), 'The ref as sent');
    Assert.areEqual(version.Id, claim.getVersionId(), 'The version Id');
    Assert.areEqual(42, claim.getSize(), 'The size');
    Assert.areEqual(UPLOADER, claim.getUploadedById(), 'The uploader');
    Assert.isNull(claim.getError(), 'No error');
  }

  @IsTest
  static void found_nullVersion_throws() {
    try {
      PayloadClaim.found('ref', null);
      Assert.fail('Expected IllegalArgumentException');
    } catch (IllegalArgumentException e) {
      Assert.isTrue(e.getMessage().contains('ContentVersion'), e.getMessage());
    }
  }

  @IsTest
  static void problemFor_theUploader_isNone() {
    PayloadClaim claim = PayloadClaim.found('ref', EventIngestionTestFactory.version(UPLOADER, 1, null));

    Assert.isNull(claim.problemFor(UPLOADER), 'The uploader may claim its own file');
  }

  @IsTest
  static void problemFor_anotherProducerOrNone_refuses() {
    PayloadClaim claim = PayloadClaim.found('ref', EventIngestionTestFactory.version(UPLOADER, 1, null));

    String other = claim.problemFor(FakeId.generate(User.SObjectType));
    Assert.isTrue(other != null && other.contains('was not uploaded by the producer'), other);
    Assert.isNotNull(claim.problemFor(null), 'An unknown producer proves nothing');
  }

  @IsTest
  static void problemFor_unusableClaim_returnsItsError() {
    PayloadClaim claim = PayloadClaim.unusable('ref', 'Not visible.');

    Assert.areEqual('Not visible.', claim.problemFor(UPLOADER), 'Its own error, whoever asks');
    Assert.isNull(claim.getVersionId(), 'No version');
    Assert.isNull(claim.getSize(), 'No size');
  }
}
