#include "LyricoTagCore.hpp"
#include <cstdio>
#include <fstream>
#include <sstream>
#include <cstring>
using namespace lyrico;
static int fails = 0;
#define CHECK(c) do { if (!(c)) { printf("FAIL %s:%d %s\n", __FILE__, __LINE__, #c); fails++; } } while (0)
static std::string slurp(const char* p){ std::ifstream f(p, std::ios::binary); std::stringstream s; s<<f.rdbuf(); return s.str(); }
static void copy(const char* a, const char* b){ std::ofstream o(b, std::ios::binary); o<<slurp(a); }
int main(int argc, char** argv) {
  const char* files[] = {"lame_cbr.mp3","sinewave.flac","test.ogg","has-tags.m4a","empty.wav","mac-399.ape","correctness_gain_silent_output.opus","lossless.wma"};
  std::string d = argv[1];
  for (auto f : files) {
    std::string src = d + "/" + f, dst = std::string("/tmp/") + f;
    copy(src.c_str(), dst.c_str());
    CoreAudioProperties ap; std::string err;
    bool ok = readAudioProperties(dst.c_str(), 1, ap, &err);
    printf("%s props ok=%d len=%d br=%d sr=%d ch=%d %s\n", f, ok, ap.length, ap.bitrate, ap.sampleRate, ap.channels, err.c_str());
    CHECK(ok);
    CorePropertyList up = {{"TITLE", {"标题 Ünïcode"}}, {"ARTIST", {"A", "B"}}, {"LYRICS", {"[00:01.00]line1\n[00:02.00]line2"}}, {"MYCUSTOM", {"x"}}, {"COMMENT", {""}}};
    ok = savePropertyMap(dst.c_str(), up, &err); printf("  save ok=%d %s\n", ok, err.c_str()); CHECK(ok);
    CoreMetadata md; ok = readMetadata(dst.c_str(), true, md, &err); CHECK(ok);
    bool title=false, custom=false, lyr=false;
    for (auto& p : md.properties) { if (p.first=="TITLE" && p.second.size()==1 && p.second[0]=="标题 Ünïcode") title=true; if (p.first=="MYCUSTOM") custom=true; if (p.first=="LYRICS") lyr=true; }
    printf("  title=%d custom=%d lyrics=%d typed=%d props=%zu\n", title, custom, lyr, md.supportsTypedPictures, md.properties.size());
    CHECK(title);
    std::vector<CorePicture> pics = {{std::string("\xFF\xD8\xFF\xE0" "fakejpegdata", 16), "desc", "Front Cover", "image/jpeg"}};
    ok = savePictures(dst.c_str(), pics, &err); printf("  savepic ok=%d %s\n", ok, err.c_str());
    std::vector<CorePicture> back; readPictures(dst.c_str(), back, &err);
    printf("  pics=%zu type=%s mime=%s size=%zu\n", back.size(), back.empty()?"":back[0].pictureType.c_str(), back.empty()?"":back[0].mimeType.c_str(), back.empty()?0:back[0].data.size());
    // reader-based
    std::string blob = slurp(dst.c_str());
    CoreReader r; r.length = blob.size(); r.readAt = [&](int64_t off, int64_t n, char* out)->int64_t{ if (off>= (int64_t)blob.size()) return 0; int64_t k = std::min<int64_t>(n, blob.size()-off); memcpy(out, blob.data()+off, k); return k; };
    CoreMetadata md2; ok = readMetadata(r, true, md2, &err); CHECK(ok); CHECK(md2.properties.size()==md.properties.size()); CHECK(md2.pictures.size()==back.size());
    ok = savePictures(dst.c_str(), {}, &err); readPictures(dst.c_str(), back, &err); CHECK(back.empty());
    std::vector<std::string> vals; readPropertyValues(dst.c_str(), "ARTIST", vals, &err); printf("  artist values=%zu\n", vals.size());
  }
  printf("fails=%d\n", fails); return fails;
}
