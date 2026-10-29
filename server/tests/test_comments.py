"""Comments: InnerTube watch-page comments -> GData comment feed."""
import xml.etree.ElementTree as ET

from ytserver import comments
from ytserver.innertube import InnerTube

ATOM = "{http://www.w3.org/2005/Atom}"


def _cont(token):
    return {"continuationEndpoint": {"continuationCommand": {"token": token}}}


def _thread(cid):
    return {"commentThreadRenderer": {
        "replies": {"commentRepliesRenderer": {"contents": [{"continuationItemRenderer": _cont("REPLIES-" + cid)}]}},
        "commentViewModel": {"commentViewModel": {"commentId": cid, "commentKey": "K" + cid}}}}


def _payload(cid, text, level=0):
    return {"payload": {"commentEntityPayload": {
        "properties": {"commentId": cid, "content": {"content": text}, "publishedTime": "2 years ago (edited)",
                       "replyLevel": level},
        "author": {"channelId": "UC" + "x" * 22, "displayName": "@someone"},
        "toolbar": {"likeCountNotliked": "4.8K", "replyCount": "12"}}}}


def _page(ids, token, reload=True):
    """One comments page; the mutations list is deliberately in another order than the threads."""
    items = [_thread(c) for c in ids] + ([{"continuationItemRenderer": _cont(token)}] if token else [])
    if reload:
        eps = [{"reloadContinuationItemsCommand": {"slot": "RELOAD_CONTINUATION_SLOT_HEADER",
                                                   "continuationItems": [{"commentsHeaderRenderer": {}}]}},
               {"reloadContinuationItemsCommand": {"slot": "RELOAD_CONTINUATION_SLOT_BODY",
                                                   "continuationItems": items}}]
    else:
        eps = [{"appendContinuationItemsAction": {"continuationItems": items}}]
    muts = [_payload(c, "text " + c) for c in reversed(ids)] + [_payload("R1", "a reply", level=1)]
    return {"onResponseReceivedEndpoints": eps, "frameworkUpdates": {"entityBatchUpdate": {"mutations": muts}}}


def _watch(token):
    section = {"itemSectionRenderer": {"sectionIdentifier": "comment-item-section",
                                       "contents": [{"continuationItemRenderer": _cont(token)}]}}
    related = {"secondaryResults": {"results": [{"continuationItemRenderer": _cont("RELATED")}]}}
    return {"contents": {"twoColumnWatchNextResults": {"results": {"results": {"contents": [section]}}, **related}}}


def test_comments_token_is_the_comment_section_not_related():
    assert comments.comments_token(_watch("CMT")) == "CMT"
    assert comments.comments_token({"contents": {}}) == ""


def test_extract_keeps_thread_order_and_skips_replies():
    page = comments.extract(_page(["A", "B", "C"], "NEXT"))
    assert [c.id for c in page.comments] == ["A", "B", "C"]
    first = page.comments[0]
    assert (first.text, first.author, first.likes, first.replies) == ("text A", "@someone", 4800, 12)
    assert first.published is not None
    assert page.token == "NEXT"


def test_extract_last_page_has_no_token():
    assert comments.extract(_page(["A"], "", reload=False)).token == ""


class FakeIT(InnerTube):
    def __init__(self):
        super().__init__()
        self.calls = []

    def call(self, endpoint, body):
        self.calls.append(body)
        if "videoId" in body:
            return _watch("P1")
        n = int(body["continuation"][1:])
        ids = [f"c{n}-{i}" for i in range(20)]
        return _page(ids, f"P{n + 1}" if n < 3 else "", reload=n == 1)


def test_comments_page_through_continuations_until_the_end():
    it = FakeIT()
    page, more = it.comments("jNQXAC9IVRw", 30)
    assert len(page.comments) >= 30 and more
    page, more = it.comments("jNQXAC9IVRw", 200)
    assert len(page.comments) == 60 and not more


def test_comment_feed_route():
    from ytserver import config
    from ytserver.app import create_app

    class NoStreams:
        def prefetch(self, vid):
            pass

    app = create_app(config.load(), innertube=FakeIT(), streams=NoStreams(), thumb_proxy=object())
    resp = app.test_client().get("/feeds/api/videos/jNQXAC9IVRw/comments?v=2&max-results=25")
    assert resp.status_code == 200
    root = ET.fromstring(resp.data)
    entries = root.findall(ATOM + "entry")
    assert len(entries) == 25
    assert entries[0].findtext(ATOM + "content") == "text c1-0"
    assert entries[0].findtext(ATOM + "id").endswith(":comment:c1-0")
    assert any(l.get("rel") == "next" for l in root.findall(ATOM + "link"))
