# Only official Linux aarch64 release assets. beta/rc are NOT nightly.
def candidate($channel):
  select(.draft==false) |
  select(if $channel=="nightly" then (.tag_name|test("(^|[-_])nightly([-_.0-9]|$)";"i"))
    else .prerelease==false and (.tag_name|test("^v[0-9]+\\.[0-9]+\\.[0-9]+$")) end) |
  select(.tag_name|test("^[A-Za-z0-9][A-Za-z0-9._-]{0,95}$")) |
  . as $r | .assets[] |
  select(.name==("trusttunnel_client-"+$r.tag_name+"-linux-aarch64.tar.gz")) |
  select(.digest|type=="string" and test("^sha256:[a-f0-9]{64}$")) |
  select(.size|type=="number" and .>0 and .<=33554432) |
  select(.browser_download_url==("https://github.com/TrustTunnel/TrustTunnelClient/releases/download/"+$r.tag_name+"/"+.name)) |
  select($r.id|type=="number" and .>0 and floor==.) |
  {release_id:$r.id,tag:$r.tag_name,channel:$channel,published_at:$r.published_at,
    name,url:.browser_download_url,sha256:(.digest[7:]),size};
[.[]|candidate($channel)] | sort_by(if $channel=="stable" then (.tag[1:]|split(".")|map(tonumber)) else .published_at end) | last // null
