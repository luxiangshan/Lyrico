function searchSongs(req) {
  var items = JSON.parse(MockApi.get(req.config, "/search", { keyword: req.keyword }));
  return items.map(function (it) {
    return { id: String(it.id), title: it.title, artist: it.artist, album: it.album, duration: it.durationMs,
             picUrl: it.cover || "", fields: { date: it.year || "" } };
  });
}

function getLyrics(req) {
  var text = MockApi.get(req.config, "/lyric", { id: req.song.id });
  if (!text) return [];
  return [{ type: "rawPlainLrc", rawPlainLrc: text, tags: { ti: req.song.title, ar: req.song.artist, al: req.song.album } }];
}

function searchCovers(req) {
  var items = JSON.parse(MockApi.get(req.config, "/search", { keyword: req.keyword }));
  return items.filter(function (it) { return it.cover; }).map(function (it) {
    return { title: it.title, artist: it.artist, album: it.album, year: it.year || "", picUrl: it.cover };
  });
}
