/**
 * @description Builds the producer idempotency key, `Source + ':' + External Message Id`, that
 * `Inbound_Message__c.Idempotency_Key__c` makes unique (ADR 0003).
 *
 * The key is taken exactly as the producer sent it: it isn't trimmed or lower-cased, because the
 * field is case-sensitive and two producers' Ids may differ only in case. The source may not
 * contain `:`, or `a:b` + `c` and `a` + `b:c` would build the same key. The field lengths (80 + 1 +
 * 160) fit the key's 255 characters, so the key can't be too long.
 * @group Public API
 */
public with sharing class IdempotencyKey {
  /** @description Separates the source from the producer's message Id. */
  public static final String SEPARATOR = ':';

  /**
   * @description Builds the key for one message.
   * @param source The producing system, for example `erp`. Required, without `:`.
   * @param externalMessageId The producer's own message Id. Required; may contain `:`.
   * @return The key.
   * @throws IllegalArgumentException If either part is blank or the source contains `:`.
   */
  public static String of(String source, String externalMessageId) {
    if (String.isBlank(source)) {
      throw new IllegalArgumentException('The message has no Source__c, so it has no idempotency key.');
    }
    if (String.isBlank(externalMessageId)) {
      throw new IllegalArgumentException('The message has no External_Message_Id__c, so it has no idempotency key.');
    }
    if (source.contains(SEPARATOR)) {
      throw new IllegalArgumentException(
        'Source__c "' + source + '" contains "' + SEPARATOR + '", which would make idempotency keys ambiguous.'
      );
    }
    return source + SEPARATOR + externalMessageId;
  }
}
