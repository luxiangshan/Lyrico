// HTTP helper: every call goes through the host API (Platform.http.getText), like the official plugins.
var MockApi = {
  get: function (config, path, params) {
    var base = String(config.baseUrl || "").replace(/\/+$/, "");
    var q = [];
    for (var k in params) q.push(encodeURIComponent(k) + "=" + encodeURIComponent(params[k]));
    return Platform.http.getText(base + "/m" + path + (q.length ? "?" + q.join("&") : ""), { headers: { "Accept": "application/json" } });
  }
};
