/**
 * @description The Claim Check port (ADR 0008). A payload over `Payload__c`'s 131,072 characters
 * travels as a `ContentVersion` the producer uploads, and the message carries its Id in
 * `Payload_Ref__c`. The store inspects each claim before it accepts the message, and dispatch
 * resolves the claims into text for the handlers. Resolve it with
 * `(IPayloadResolver) Application.Service.newInstance(IPayloadResolver.class)`; the
 * `DI_Binding.Payload_Resolver` row binds `ContentVersionPayloadResolver`.
 * @group Public API
 */
public interface IPayloadResolver {
  /**
   * @description Looks up each claim without loading its content: whether it names a visible
   * `ContentVersion`, its size and its uploader. A ref that isn't a `ContentVersion` Id, isn't
   * visible, or is larger than `Ingestion_Setting__mdt.Claim_Max_Bytes__c` comes back unusable.
   * Limits: at most 1 SOQL (user mode, no file data); none for an empty set.
   * @param refs `Payload_Ref__c` values; null or empty returns an empty map.
   * @return One claim per ref, keyed by the ref as given.
   */
  Map<String, PayloadClaim> inspect(Set<String> refs);

  /**
   * @description Loads the claimed files as UTF-8 text. Loading costs about twice a file's size in
   * heap while it is converted (probe 7), so callers bound the total with
   * `Dispatch_Payload_Budget__c`. Limits: at most 1 SOQL (user mode, with file data).
   * @param refs `Payload_Ref__c` values; null or empty returns an empty map.
   * @return The text per ref. A ref whose file is missing, not visible or not valid UTF-8 is left
   * out, so the caller can fail that message.
   */
  Map<String, String> resolve(Set<String> refs);
}
