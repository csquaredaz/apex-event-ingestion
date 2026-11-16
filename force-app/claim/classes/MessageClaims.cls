/**
 * @description Applies Claim Check to messages on their way into the store (ADR 0008). Every claim
 * is inspected through one `IPayloadResolver.inspect` call and must name a version its own
 * producer uploaded, within `Claim_Max_Bytes__c`. A usable claim is normalised in place: the ref
 * becomes the 18-character version Id and `Payload_Size__c` the file's size. `MessageStore` calls it
 * before the insert and rejects the rest.
 * @group Claim Check
 */
public with sharing class MessageClaims {
  /**
   * @description Checks the claimed rows. Limits: at most 1 SOQL (through the resolver); none
   * when no row is claimed. Bulk-safe at 200.
   * @param rows Unsaved rows; rows without `Payload_Ref__c` are left alone.
   * @param producerIds The producer of each row, in the same order.
   * @return The reason each unusable claim is refused, keyed by its row's position.
   */
  public static Map<Integer, String> check(List<Inbound_Message__c> rows, List<Id> producerIds) {
    Map<Integer, String> problems = new Map<Integer, String>();
    Set<String> refs = refsOf(rows);
    if (refs.isEmpty()) {
      return problems;
    }
    Map<String, PayloadClaim> claims = ((IPayloadResolver) Application.Service.newInstance(IPayloadResolver.class))
      .inspect(refs);
    for (Integer i = 0; i < rows.size(); i++) {
      String problem = apply(rows[i], claims.get(rows[i].Payload_Ref__c), producerIds[i]);
      if (problem != null) {
        problems.put(i, problem);
      }
    }
    return problems;
  }

  private static Set<String> refsOf(List<Inbound_Message__c> rows) {
    Set<String> refs = new Set<String>();
    for (Inbound_Message__c row : rows) {
      if (String.isNotBlank(row.Payload_Ref__c)) {
        refs.add(row.Payload_Ref__c);
      }
    }
    return refs;
  }

  /** An inline row has no problem. A usable claim is normalised in place; otherwise the reason. */
  private static String apply(Inbound_Message__c row, PayloadClaim claim, Id producerId) {
    if (String.isBlank(row.Payload_Ref__c)) {
      return null;
    }
    if (claim == null) {
      return 'The claim ' + row.Payload_Ref__c + ' was not inspected.';
    }
    String problem = claim.problemFor(producerId);
    if (problem == null) {
      row.Payload_Ref__c = claim.getVersionId();
      row.Payload_Size__c = claim.getSize();
    }
    return problem;
  }
}
