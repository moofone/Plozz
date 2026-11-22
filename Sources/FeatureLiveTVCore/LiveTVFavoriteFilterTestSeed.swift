import CoreModels

#if DEBUG
/// TEST-ONLY: a favourite filter that comes with Debug builds so the filter flow can be tried without making one — "Canada News",
/// channels with both the Canada and the News tag. It is an ordinary user filter once added: listed, editable and deletable, and it is
/// offered once per profile, so deleting it keeps it deleted. Remove this file and its one use in `LiveTVFavoriteFilterState.init` to
/// drop it; release builds do not contain it.
enum LiveTVFavoriteFilterTestSeed {
    static let filter = LiveTVFavoriteFilter(
        id: "test-seed.canada-news",
        tagIDs: [LiveTVFilterTagCatalog.tagID("Canada"), LiveTVFilterTagCatalog.tagID("News")],
        name: "Canada News")
}
#endif
