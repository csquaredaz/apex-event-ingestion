/**
 * @description What the store learns about one claim check before it accepts the message (ADR 0008):
 * the `ContentVersion` the ref names, that version's size and uploader, or why it can't be used.
 * Built by `IPayloadResolver.inspect`. Immutable.
 * @group Public API
 */
public with sharing class PayloadClaim {
  private final String ref;
  private final Id versionId;
  private final Integer size;
  private final Id uploadedById;
  private final String error;

  private PayloadClaim(String ref, ContentVersion version, String error) {
    this.ref = ref;
    this.versionId = version?.Id;
    this.size = version?.ContentSize;
    this.uploadedById = version?.CreatedById;
    this.error = error;
  }

  /**
   * @description A claim that names a visible version within the size cap.
   * @param ref The `Payload_Ref__c` value as the producer sent it.
   * @param version The version, queried with `ContentSize` and `CreatedById`.
   * @return The claim.
   * @throws IllegalArgumentException If the version is null.
   */
  public static PayloadClaim found(String ref, ContentVersion version) {
    if (version == null) {
      throw new IllegalArgumentException('A found PayloadClaim needs its ContentVersion.');
    }
    return new PayloadClaim(ref, version, null);
  }

  /**
   * @description A claim the store must reject.
   * @param ref The `Payload_Ref__c` value as the producer sent it.
   * @param error Why it can't be used, without any payload content.
   * @return The claim.
   */
  public static PayloadClaim unusable(String ref, String error) {
    return new PayloadClaim(ref, null, error);
  }

  /** @description @return The `Payload_Ref__c` value as the producer sent it. */
  public String getRef() {
    return ref;
  }

  /** @description @return The version's 18-character Id, or null for an unusable claim. */
  public Id getVersionId() {
    return versionId;
  }

  /** @description @return The version's size in bytes, or null for an unusable claim. */
  public Integer getSize() {
    return size;
  }

  /** @description @return Who uploaded the version, or null for an unusable claim. */
  public Id getUploadedById() {
    return uploadedById;
  }

  /** @description @return Why the claim can't be used, or null when it names a usable version. */
  public String getError() {
    return error;
  }

  /**
   * @description The confused-deputy guard (ADR 0008). The processor can read every file in the org
   * (probe 7), so a claim is honoured only when the producer itself uploaded that version; otherwise
   * a producer could have the processor read a file it can't see.
   * @param producerId The user who produced the message: the event's publisher, or the caller.
   * @return Why this producer can't use the claim, or null when it can.
   */
  public String problemFor(Id producerId) {
    if (error != null) {
      return error;
    }
    if (producerId == null || producerId != uploadedById) {
      return 'ContentVersion ' + versionId + ' was not uploaded by the producer, so it cannot be claimed.';
    }
    return null;
  }
}
