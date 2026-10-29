import pytest

from ytserver import ids


@pytest.mark.parametrize("value", ["jNQXAC9IVRw", "dQw4w9WgXcQ", "a_b-c_d-e_f", "___________"])
def test_valid_video_ids(value):
    assert ids.is_video_id(value)


@pytest.mark.parametrize("value", [
    None, "", "short", "toolongvideoid1", "jNQXAC9IVR!", "jNQXAC9IVR ", "../etc/pwd",
    "jNQXAC9IVRw\n", "jNQXAC9IV;w", "jNQXAC9IVRé",
])
def test_invalid_video_ids(value):
    assert not ids.is_video_id(value)


def test_channel_and_playlist_ids():
    assert ids.is_channel_id("UCJZam2u1G0syq3kyqrCXrNw")
    assert not ids.is_channel_id("UCshort")
    assert ids.is_playlist_id("PLrEnWoR732-BHrPp_Pm8_VleD68f9s14-")
    assert not ids.is_playlist_id("PL;rm -rf")


def test_clean_query_strips_control_chars_and_caps_length():
    assert ids.clean_query("  mine\x00craft \n\t videos ") == "mine craft videos"
    assert len(ids.clean_query("x" * 1000)) == ids.MAX_QUERY_LEN
    assert ids.clean_query(None) == ""


@pytest.mark.parametrize("start,count,expect", [
    (None, None, (1, 25)), ("0", "0", (1, 1)), ("-5", "999", (1, 50)),
    ("abc", "xyz", (1, 25)), ("26", "10", (26, 10)), ("99999", "5", (500, 5)),
])
def test_paging_clamps(start, count, expect):
    assert ids.paging(start, count) == expect
