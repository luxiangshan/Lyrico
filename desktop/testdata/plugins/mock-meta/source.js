// Metadata test source: returns full song info (album, album artist, genre, date, track, disc, composer, lyricist),
// a cover URL and lyrics, all served by a mock HTTP server. Fields the server omits are simply absent.
function searchSongs(req) {
  var items = JSON.parse(MockApi.get(req.config, "/search", { keyword: req.keyword }));
  return items.map(function (it) {
    return { id: String(it.id), title: it.title, artist: it.artist, album: it.album || "", duration: it.durationMs || 0,
             picUrl: it.cover || "", fields: it.fields || {} };
  });
}

function getLyrics(req) {
  var text = MockApi.get(req.config, "/lyric", { id: req.song.id });
  if (!text) return [];
  return [{ type: "rawPlainLrc", rawPlainLrc: text, tags: { ti: req.song.title, ar: req.song.artist } }];
}

function searchCovers(req) {
  var items = JSON.parse(MockApi.get(req.config, "/search", { keyword: req.keyword }));
  return items.filter(function (it) { return it.cover; }).map(function (it) {
    return { title: it.title, artist: it.artist, album: it.album || "", year: "", picUrl: it.cover };
  });
}
