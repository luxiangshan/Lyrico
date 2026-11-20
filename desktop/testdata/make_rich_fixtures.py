#!/usr/bin/env python3
"""Generates src/test/resources/audio/rich/*: realistic, heavily tagged files written by an independent tagger (mutagen).
Three songs per variant with different artists, titles and covers (and the same frame set), used by RichTagPreservationTest.
Run from desktop/:  python3 testdata/make_rich_fixtures.py"""
import base64, os, shutil, struct, subprocess
from mutagen.id3 import (ID3, ID3v1SaveOptions, TIT2, TPE1, TALB, TPE2, TCOM, TEXT, TPOS, TRCK, TCON, TDRC, TYER, COMM, USLT,
                         APIC, TXXX, TSRC, TCOP, TBPM, TKEY, TPUB, WXXX, POPM, UFID, PRIV, TSOP, TSOA, TIT3, TLAN)
from mutagen.flac import FLAC, Picture
from mutagen.mp4 import MP4, MP4Cover, MP4FreeForm
from mutagen.oggvorbis import OggVorbis
from mutagen.oggopus import OggOpus
from mutagen.apev2 import APEv2, APEValue, BINARY

SRC = "src/test/resources/audio"
OUT = os.path.join(SRC, "rich")
shutil.rmtree(OUT, ignore_errors=True)
os.makedirs(OUT)

COLORS = ["#c0392b", "#27ae60", "#2980b9"]
def make_cover(i):
    p = f"/tmp/rich_cover{i}.jpg"
    subprocess.run(["ffmpeg", "-loglevel", "error", "-y", "-f", "lavfi", "-i", f"testsrc2=size=300x300:rate=1,drawbox=c={COLORS[i]}@0.6:t=fill:x={i*40}:w=100",
                    "-frames:v", "1", "-q:v", "4", p], check=True)
    return open(p, "rb").read()
COVERS = [make_cover(i) for i in range(3)]
open(os.path.join(OUT, "cover_back.png"), "wb").write(open(os.path.join(SRC, "cover.png"), "rb").read())
BACK = open(os.path.join(SRC, "cover.png"), "rb").read()

ARTISTS = ["周杰伦", "陈奕迅", "王菲 / 那英"]
TITLES = ["晴天", "十年", "相约九八"]
LYR = "[00:01.00]第一行 {n}\n[00:05.50]第二行 {n}\n"

def id3_frames(i):
    return [
        TIT2(encoding=3, text=[TITLES[i]]), TPE1(encoding=3, text=[ARTISTS[i]]), TALB(encoding=3, text=["原专辑 %d" % i]),
        TPE2(encoding=3, text=["专辑艺术家 %d" % i]), TCOM(encoding=3, text=["作曲 %d" % i]), TEXT(encoding=3, text=["作词 %d" % i]),
        TPOS(encoding=3, text=["%d/2" % (i % 2 + 1)]), TRCK(encoding=3, text=["%d/12" % (i + 3)]), TCON(encoding=3, text=["流行"]),
        COMM(encoding=3, lang="chi", desc="", text=["注释 %d" % i]), COMM(encoding=3, lang="eng", desc="iTunNORM", text=[" 000001A2 000001B3"]),
        USLT(encoding=3, lang="chi", desc="", text=LYR.format(n=i)),
        APIC(encoding=3, mime="image/jpeg", type=3, desc="", data=COVERS[i]), APIC(encoding=0, mime="image/png", type=4, desc="back", data=BACK),
        TXXX(encoding=3, desc="REPLAYGAIN_TRACK_GAIN", text=["-7.%02d dB" % i]), TXXX(encoding=3, desc="REPLAYGAIN_TRACK_PEAK", text=["0.98%d" % i]),
        TXXX(encoding=3, desc="REPLAYGAIN_ALBUM_GAIN", text=["-6.50 dB"]), TXXX(encoding=3, desc="MusicBrainz Album Id", text=["mbid-%d" % i]),
        TXXX(encoding=3, desc="自定义", text=["中文自定义值 %d" % i]),
        TSRC(encoding=3, text=["TWK97030%04d" % i]), TCOP(encoding=3, text=["© 2003 测试唱片"]), TBPM(encoding=3, text=["%d" % (90 + i)]),
        TKEY(encoding=3, text=["Am"]), TPUB(encoding=3, text=["出版商"]), TSOP(encoding=3, text=["sort artist %d" % i]),
        TSOA(encoding=3, text=["sort album"]), TIT3(encoding=3, text=["副标题"]), TLAN(encoding=3, text=["chi"]),
        WXXX(encoding=3, desc="官网", url="https://example.com/%d" % i), POPM(email="user@example.com", rating=196, count=7),
        UFID(owner="http://musicbrainz.org", data=b"ufid-%d" % i), PRIV(owner="WM/MediaClassPrimaryID", data=b"\x01\x02\x03\x04"),
    ]

def mp3(i, v2, v1, name):
    dst = os.path.join(OUT, name)
    shutil.copy(os.path.join(SRC, "sample.mp3"), dst)
    t = ID3()
    for f in id3_frames(i):
        t.add(f)
    if v2 == 3:
        t.add(TYER(encoding=1, text=["2003"]))
        t.delall("TDRC")
        t.update_to_v23()
    else:
        t.add(TDRC(encoding=3, text=["2003-05-01"]))
    t.save(dst, v2_version=v2, v1=ID3v1SaveOptions.CREATE if v1 else ID3v1SaveOptions.REMOVE)

def vorbis_common(t, i):
    vals = {
        "TITLE": [TITLES[i]], "ARTIST": [ARTISTS[i]], "ALBUM": ["原专辑 %d" % i], "ALBUMARTIST": ["专辑艺术家 %d" % i],
        "COMPOSER": ["作曲 %d" % i], "LYRICIST": ["作词 %d" % i], "DISCNUMBER": ["%d" % (i % 2 + 1)], "DISCTOTAL": ["2"],
        "TRACKNUMBER": ["%d" % (i + 3)], "TRACKTOTAL": ["12"], "GENRE": ["流行", "华语"], "DATE": ["2003-05-01"],
        "COMMENT": ["注释 %d" % i], "LYRICS": [LYR.format(n=i)],
        "REPLAYGAIN_TRACK_GAIN": ["-7.%02d dB" % i], "REPLAYGAIN_TRACK_PEAK": ["0.98%d" % i], "REPLAYGAIN_ALBUM_GAIN": ["-6.50 dB"],
        "REPLAYGAIN_ALBUM_PEAK": ["0.999"], "MUSICBRAINZ_ALBUMID": ["mbid-%d" % i], "ISRC": ["TWK97030%04d" % i],
        "COPYRIGHT": ["© 2003 测试唱片"], "BPM": ["%d" % (90 + i)], "LABEL": ["出版商"], "X_CUSTOM": ["中文自定义值 %d" % i],
        "ARTISTSORT": ["sort artist %d" % i], "ENCODER": ["mutagen test"], "PERFORMER": ["演奏者 A", "演奏者 B"],
    }
    for k, v in vals.items():
        t[k] = v

def picture(data, mime, ptype, desc):
    p = Picture(); p.data = data; p.mime = mime; p.type = ptype; p.desc = desc
    p.width = p.height = 300 if mime == "image/jpeg" else 1; p.depth = 24
    return p

def flac(i):
    dst = os.path.join(OUT, "rich%d.flac" % i)
    shutil.copy(os.path.join(SRC, "sample.flac"), dst)
    f = FLAC(dst)
    if f.tags is None:
        f.add_tags()
    f.clear_pictures()
    vorbis_common(f, i)
    f.add_picture(picture(COVERS[i], "image/jpeg", 3, ""))
    f.add_picture(picture(BACK, "image/png", 4, "back"))
    f.save()

def ogg(cls, src, i, ext):
    dst = os.path.join(OUT, "rich%d.%s" % (i, ext))
    shutil.copy(os.path.join(SRC, src), dst)
    f = cls(dst)
    if f.tags is None:
        f.add_tags()
    vorbis_common(f, i)
    f["METADATA_BLOCK_PICTURE"] = [base64.b64encode(picture(COVERS[i], "image/jpeg", 3, "").write()).decode(),
                                   base64.b64encode(picture(BACK, "image/png", 4, "back").write()).decode()]
    f.save()

def m4a(i):
    dst = os.path.join(OUT, "rich%d.m4a" % i)
    shutil.copy(os.path.join(SRC, "sample.m4a"), dst)
    f = MP4(dst)
    if f.tags is None:
        f.add_tags()
    f["\xa9nam"] = [TITLES[i]]; f["\xa9ART"] = [ARTISTS[i]]; f["\xa9alb"] = ["原专辑 %d" % i]; f["aART"] = ["专辑艺术家 %d" % i]
    f["\xa9wrt"] = ["作曲 %d" % i]; f["\xa9gen"] = ["流行"]; f["\xa9day"] = ["2003-05-01"]; f["\xa9cmt"] = ["注释 %d" % i]
    f["\xa9lyr"] = [LYR.format(n=i)]; f["trkn"] = [(i + 3, 12)]; f["disk"] = [(i % 2 + 1, 2)]; f["tmpo"] = [90 + i]
    f["cprt"] = ["© 2003 测试唱片"]; f["soar"] = ["sort artist %d" % i]; f["\xa9too"] = ["mutagen test"]; f["cpil"] = False
    f["----:com.apple.iTunes:replaygain_track_gain"] = [MP4FreeForm(("-7.%02d dB" % i).encode())]
    f["----:com.apple.iTunes:LYRICIST"] = [MP4FreeForm(("作词 %d" % i).encode())]
    f["----:com.apple.iTunes:MusicBrainz Album Id"] = [MP4FreeForm(("mbid-%d" % i).encode())]
    f["----:com.apple.iTunes:X_CUSTOM"] = [MP4FreeForm(("中文自定义值 %d" % i).encode())]
    f["covr"] = [MP4Cover(COVERS[i], imageformat=MP4Cover.FORMAT_JPEG), MP4Cover(BACK, imageformat=MP4Cover.FORMAT_PNG)]
    f.save()

def ape(i, ext):
    dst = os.path.join(OUT, "rich%d.%s" % (i, ext))
    shutil.copy(os.path.join(SRC, "sample." + ext), dst)
    try:
        APEv2(dst).delete()
    except Exception:
        pass
    t = APEv2()
    vals = {"Title": TITLES[i], "Artist": ARTISTS[i], "Album": "原专辑 %d" % i, "Album Artist": "专辑艺术家 %d" % i, "Composer": "作曲 %d" % i,
            "Lyricist": "作词 %d" % i, "Disc": "%d/2" % (i % 2 + 1), "Track": "%d/12" % (i + 3), "Genre": "流行", "Year": "2003",
            "Comment": "注释 %d" % i, "Lyrics": LYR.format(n=i), "REPLAYGAIN_TRACK_GAIN": "-7.%02d dB" % i, "REPLAYGAIN_TRACK_PEAK": "0.98%d" % i,
            "MUSICBRAINZ_ALBUMID": "mbid-%d" % i, "ISRC": "TWK97030%04d" % i, "X_Custom": "中文自定义值 %d" % i, "Copyright": "© 2003 测试唱片"}
    for k, v in vals.items():
        t[k] = v
    t["Cover Art (Front)"] = APEValue(b"cover.jpg\x00" + COVERS[i], BINARY)
    t["Cover Art (Back)"] = APEValue(b"back.png\x00" + BACK, BINARY)
    t.save(dst)

for i in range(3):
    mp3(i, 4, False, "rich%d_v24.mp3" % i)
    mp3(i, 3, True, "rich%d_v23v1.mp3" % i)
    flac(i); m4a(i)
    ogg(OggVorbis, "sample.ogg", i, "ogg")
    ogg(OggOpus, "sample.opus", i, "opus")
    ape(i, "ape"); ape(i, "wv")
print(sorted(os.listdir(OUT)))
