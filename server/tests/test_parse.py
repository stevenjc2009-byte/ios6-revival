from datetime import datetime, timedelta, timezone

from ytserver import parse


def test_search_videos_fixture(fixture):
    page = parse.extract(fixture("search_videos.json"))
    assert len(page.videos) == 2
    for v in page.videos:
        assert len(v.id) == 11 and v.title and v.author
        assert v.duration > 0


def test_search_channels_fixture(fixture):
    page = parse.extract(fixture("search_channels.json"))
    assert len(page.channels) == 1
    assert page.channels[0].id.startswith("UC") and page.channels[0].title


def test_related_lockups_have_views_and_dates(fixture):
    """Regression: counts live in accessibilityLabel / '10M' text, ages in '1y ago'."""
    page = parse.extract(fixture("related_lockups.json"))
    assert len(page.videos) == 2
    for v in page.videos:
        assert v.views > 0
        assert v.published is not None and v.published.year >= 2000
        assert v.author


def test_player_fixture_has_exact_publish_date(fixture):
    v = parse.video_from_player(fixture("player.json"))
    assert v.id == "jNQXAC9IVRw"
    assert v.title == "Me at the zoo" and v.duration == 19
    assert v.published == datetime(2005, 4, 24, 3, 31, 52, tzinfo=timezone.utc)
    assert v.views > 1_000_000


def test_player_without_details_is_none():
    assert parse.video_from_player({"playabilityStatus": {"status": "ERROR"}}) is None


def test_parse_age_is_relative_to_now():
    now = datetime(2026, 1, 1, tzinfo=timezone.utc)
    assert parse.parse_age("2 days ago", now) == now - timedelta(days=2)
    assert parse.parse_age("1 year ago", now) == now - timedelta(days=365)
    assert parse.parse_age("Streamed live", now) is None
    assert parse.parse_age("", now) is None


def test_parse_duration():
    assert parse.parse_duration("1:02:03") == 3723
    assert parse.parse_duration("12:34") == 754
    assert parse.parse_duration("LIVE") == 0


def test_garbage_documents_yield_empty_pages():
    for doc in ({}, [], None, {"contents": "x"}, {"a": [1, 2, {"videoRenderer": {"videoId": "bad"}}]}):
        page = parse.extract(doc)
        assert not (page.videos or page.channels or page.playlists)


def _cont(token):
    return {"continuationEndpoint": {"continuationCommand": {"token": token}}}


def test_continuation_is_the_load_more_token_not_a_filter_chip():
    """Regression: the search header's chips (Shorts, Videos, ...) carry
    continuation tokens too; following one looped pages after ~45 results."""
    header = {"chipCloudRenderer": {"chips": [
        {"chipCloudChipRenderer": {"navigationEndpoint": {"continuationCommand": {"token": "CHIP1"}}}},
        {"chipCloudChipRenderer": {"navigationEndpoint": {"continuationCommand": {"token": "CHIP2"}}}}]}}
    contents = [{"itemSectionRenderer": {}}, {"continuationItemRenderer": _cont("MORE")}]
    assert parse.continuation_token({"header": header, "contents": contents}) == "MORE"
    assert parse.continuation_token({"contents": contents, "header": header}) == "MORE"


def test_continuation_falls_back_to_any_token():
    assert parse.continuation_token({"a": [{"x": _cont("ONLY")}]}) == "ONLY"
    assert parse.continuation_token({"a": 1}) == ""


def test_related_continuation_is_the_results_list_not_comments():
    """Regression: the watch page has a comments 'load more' first; related stopped at 20."""
    comments = [{"continuationItemRenderer": _cont("COMMENTS")}]
    related = [{"compactVideoRenderer": {}}] * 20 + [{"continuationItemRenderer": _cont("RELATED")}]
    for doc in ({"results": comments, "secondary": related}, {"secondary": related, "results": comments}):
        assert parse.continuation_token(doc) == "RELATED"


def test_extract_keeps_document_order():
    """Regression: results came out last-first on every page (search, uploads, playlists)."""
    ids = [f"AAAAAAAAAA{i}" for i in range(5)]
    doc = {"contents": [{"itemSectionRenderer": {"contents": [
        {"videoRenderer": {"videoId": v, "title": {"runs": [{"text": v}]}}} for v in ids[:3]]}},
        {"itemSectionRenderer": {"contents": [
            {"videoRenderer": {"videoId": v, "title": {"runs": [{"text": v}]}}} for v in ids[3:]]}}]}
    assert [v.id for v in parse.extract(doc).videos] == ids
