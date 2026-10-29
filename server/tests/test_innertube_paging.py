from ytserver import innertube
from ytserver.innertube import InnerTube


class EndlessIT(InnerTube):
    """Every page holds 2 new videos and a 'load more' token."""

    def __init__(self):
        super().__init__()
        self.calls = 0

    def call(self, endpoint, body):
        self.calls += 1
        n = self.calls
        vids = [{"videoRenderer": {"videoId": f"vid{n:04d}x{i}aa"[:11], "title": {"runs": [{"text": "t"}]}}}
                for i in range(2)]
        return {"contents": vids + [{"continuationItemRenderer": {
            "continuationEndpoint": {"continuationCommand": {"token": f"T{n}"}}}}]}


def test_paging_follows_tokens_up_to_the_cap_then_says_no_more():
    it = EndlessIT()
    page, more = it.search("q", "", 10_000)
    assert it.calls == innertube.MAX_PAGES
    assert len(page.videos) == 2 * innertube.MAX_PAGES
    assert more is False  # a "next" link here would hand the app empty pages forever


def test_paging_reports_more_below_the_cap():
    it = EndlessIT()
    page, more = it.search("q", "", 3)
    assert it.calls == 2 and more is True
