/**
 * @description Queries over `ContentVersion` for Claim Check (ADR 0008). Bound to
 * `ContentVersionsSelector` by the `DI_Binding.Content_Versions_Selector` row, so tests can stand
 * in a mock through `Application.Selector`. It queries `ContentVersion`, not `ContentDocument`: in
 * user mode a document is only visible when it is shared with the user directly (probe 7).
 * @group Claim Check
 */
public interface IContentVersionsSelector extends ISelector {
  /**
   * @description Selects versions with their size and uploader, without the file data.
   * @param ids Version Ids; null or empty returns an empty list without querying.
   * @return The versions the running user can see, in user mode.
   */
  List<ContentVersion> selectByIds(Set<Id> ids);

  /**
   * @description Selects versions with their file data (`VersionData`), which costs its size in heap.
   * @param ids Version Ids; null or empty returns an empty list without querying.
   * @return The versions the running user can see, in user mode.
   */
  List<ContentVersion> selectWithDataByIds(Set<Id> ids);
}
