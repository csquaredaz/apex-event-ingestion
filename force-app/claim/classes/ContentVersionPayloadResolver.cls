/**
 * @description The default `IPayloadResolver` (ADR 0008): claims are `ContentVersion` Ids, read in
 * user mode through `IContentVersionsSelector`. A version Id, not a document Id, so the content a
 * message names can't change after it is sent.
 *
 * No file is shared with the processor: the Automated Process user reads every version in user
 * mode, with or without a `ContentDocumentLink` (probe 7). That is why `PayloadClaim.problemFor`
 * checks the uploader instead of trusting visibility.
 * @group Claim Check
 */
public with sharing class ContentVersionPayloadResolver implements IPayloadResolver {
  /**
   * @description See `IPayloadResolver.inspect`. Limits: at most 1 SOQL, no file data.
   * @param refs `Payload_Ref__c` values.
   * @return One claim per ref.
   */
  public Map<String, PayloadClaim> inspect(Set<String> refs) {
    Map<String, PayloadClaim> claims = new Map<String, PayloadClaim>();
    Map<String, Id> versionIdByRef = parse(refs, claims);
    if (versionIdByRef.isEmpty()) {
      return claims;
    }
    Map<Id, ContentVersion> versions = new Map<Id, ContentVersion>(
      selector().selectByIds(new Set<Id>(versionIdByRef.values()))
    );
    Integer maxBytes = IngestionSettings.current().getClaimMaxBytes();
    for (String ref : versionIdByRef.keySet()) {
      claims.put(ref, judge(ref, versions.get(versionIdByRef.get(ref)), maxBytes));
    }
    return claims;
  }

  /**
   * @description See `IPayloadResolver.resolve`. Limits: at most 1 SOQL with file data. Each file's
   * data is released once it is converted, so the peak is the text plus one file, not twice the total.
   * @param refs `Payload_Ref__c` values.
   * @return The text per ref; missing, invisible or non-UTF-8 files are left out.
   */
  public Map<String, String> resolve(Set<String> refs) {
    Map<String, String> payloads = new Map<String, String>();
    Map<String, Id> versionIdByRef = parse(refs, new Map<String, PayloadClaim>());
    if (versionIdByRef.isEmpty()) {
      return payloads;
    }
    Map<Id, String> textById = new Map<Id, String>();
    for (ContentVersion version : selector().selectWithDataByIds(new Set<Id>(versionIdByRef.values()))) {
      String text = toText(version.VersionData);
      version.VersionData = null;
      if (text != null) {
        textById.put(version.Id, text);
      }
    }
    for (String ref : versionIdByRef.keySet()) {
      Id versionId = versionIdByRef.get(ref);
      if (textById.containsKey(versionId)) {
        payloads.put(ref, textById.get(versionId));
      }
    }
    return payloads;
  }

  private static PayloadClaim judge(String ref, ContentVersion version, Integer maxBytes) {
    if (version == null) {
      return PayloadClaim.unusable(ref, 'No ContentVersion ' + ref + ' is visible to the running user.');
    }
    if (version.ContentSize > maxBytes) {
      return PayloadClaim.unusable(
        ref,
        'ContentVersion ' + ref + ' is ' + version.ContentSize + ' bytes; Claim_Max_Bytes__c allows ' + maxBytes + '.'
      );
    }
    return PayloadClaim.found(ref, version);
  }

  /** Keeps the refs that are ContentVersion Ids, and records the rest as unusable. */
  private static Map<String, Id> parse(Set<String> refs, Map<String, PayloadClaim> claims) {
    Map<String, Id> versionIdByRef = new Map<String, Id>();
    for (String ref : refs == null ? new Set<String>() : refs) {
      Id versionId = toVersionId(ref);
      if (versionId == null) {
        claims.put(ref, PayloadClaim.unusable(ref, 'Payload_Ref__c ' + ref + ' is not a ContentVersion Id.'));
      } else {
        versionIdByRef.put(ref, versionId);
      }
    }
    return versionIdByRef;
  }

  private static Id toVersionId(String ref) {
    if (String.isBlank(ref)) {
      return null;
    }
    try {
      Id value = Id.valueOf(ref);
      return value.getSObjectType() == ContentVersion.SObjectType ? value : null;
    } catch (StringException notAnId) {
      return null;
    }
  }

  /** Null when the data is missing or not valid UTF-8, so dispatch fails that message. */
  private static String toText(Blob data) {
    if (data == null) {
      return null;
    }
    try {
      return data.toString();
    } catch (StringException notUtf8) {
      return null;
    }
  }

  private static IContentVersionsSelector selector() {
    return (IContentVersionsSelector) Application.Selector.newInstance(ContentVersion.SObjectType);
  }
}
