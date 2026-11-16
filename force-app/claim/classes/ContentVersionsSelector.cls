/**
 * @description Selects `ContentVersion` in user mode (apex-core-lib's `SObjectSelector`).
 * `inherited sharing`, because the store and the dispatcher call it in their own sharing context;
 * the queries are user mode either way. The standard field list leaves out `VersionData`; only
 * `selectWithDataByIds`, used by dispatch, adds it.
 * @group Claim Check
 */
public inherited sharing class ContentVersionsSelector extends SObjectSelector implements IContentVersionsSelector {
  // True only for the duration of selectWithDataByIds, so the base class's query builder includes
  // the file data; every other query leaves it out.
  private Boolean includeData = false;

  /**
   * @description The type this selector queries.
   * @return `ContentVersion.SObjectType`.
   */
  public override SObjectType getSObjectType() {
    return ContentVersion.SObjectType;
  }

  /**
   * @description The size and uploader.
   * @return The field list; `VersionData` only while `selectWithDataByIds` runs.
   */
  public override List<SObjectField> getSObjectFieldList() {
    List<SObjectField> fields = new List<SObjectField>{ ContentVersion.ContentSize, ContentVersion.CreatedById };
    if (includeData) {
      fields.add(ContentVersion.VersionData);
    }
    return fields;
  }

  /**
   * @description See `IContentVersionsSelector.selectByIds`. Limits: 1 SOQL, none for an empty set.
   * @param ids Version Ids.
   * @return The versions without file data.
   */
  public List<ContentVersion> selectByIds(Set<Id> ids) {
    return (List<ContentVersion>) selectSObjectsById(ids);
  }

  /**
   * @description See `IContentVersionsSelector.selectWithDataByIds`. Limits: 1 SOQL, none for an
   * empty set; heap of each file's size.
   * @param ids Version Ids.
   * @return The versions with their file data.
   */
  public List<ContentVersion> selectWithDataByIds(Set<Id> ids) {
    includeData = true;
    try {
      return (List<ContentVersion>) selectSObjectsById(ids);
    } finally {
      includeData = false;
    }
  }
}
