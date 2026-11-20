// Supabase Edge Function: youtube-playlist
// Reads the title, link and upload date of every video in a YouTube playlist (or a channel's uploads, newest 2,000),
// or a Bilibili channel's collections / video links, so Missing data can match VODs to games.
// Needs a secret named YOUTUBE_API_KEY (Supabase > Edge Functions > Secrets). Only signed-in users of the site can call it.
const ORIGINS = ['https://livvyrpl.github.io'];
const cors = (o: string | null) => ({
  'Access-Control-Allow-Origin': o && (ORIGINS.includes(o) || /^http:\/\/localhost(:\d+)?$/.test(o)) ? o : ORIGINS[0],
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
});

// ---- Bilibili ----
// Bilibili often refuses requests from servers (its anti-bot check), so this works only some of the time.
// A channel's own upload list is closed to servers, so a channel link reads the videos in its collections (合集 and 列表).
// One collection link reads just that one; video links (bilibili.com/video/BV...) are read one by one.
// If Bilibili refuses partway, what was already read is still returned, with a note.
type Vid = { id: string; title: string; published: string; url: string };
const BH = { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; LivAnalytics/1.0)', 'Accept': 'application/json' } };
class Refused extends Error {}
const bj = async (u: string) => {
  const r = await fetch(u, BH);
  const j: any = await r.json().catch(() => ({}));
  if (r.status === 412 || j?.code === -352 || j?.code === -412 || /banned/i.test(String(j?.message || ''))) throw new Refused('refused');
  if (j?.code !== 0) throw new Error('Bilibili said: ' + (j?.message || r.status));
  return j.data;
};
const bv = (a: any): Vid => ({ id: a.bvid, title: a.title || '', published: new Date((a.pubdate || a.ctime || 0) * 1000).toISOString(), url: 'https://www.bilibili.com/video/' + a.bvid });
async function biliList(mid: string, kind: string, lid: string, add: (v: Vid) => void) {
  for (let pn = 1; pn <= 30; pn++) {
    const d = kind === 'series'
      ? await bj(`https://api.bilibili.com/x/series/archives?mid=${mid}&series_id=${lid}&pn=${pn}&ps=100`)
      : await bj(`https://api.bilibili.com/x/polymer/web-space/seasons_archives_list?mid=${mid}&season_id=${lid}&page_num=${pn}&page_size=100`);
    const list = d?.archives || [];
    list.forEach((a: any) => add(bv(a)));
    if (!list.length || pn * 100 >= (d?.page?.total ?? 0)) break;
  }
}
async function bili(raw: string) {
  const seen = new Map<string, Vid>(), add = (v: Vid) => { if (v.id && !seen.has(v.id) && seen.size < 3000) seen.set(v.id, v) };
  const ids = [...new Set([...raw.matchAll(/\b(BV[A-Za-z0-9]{8,12})\b/g)].map((m) => m[1]))];
  const sp = raw.match(/space\.bilibili\.com\/(?:[a-z]{2}\/)?(\d+)/i);
  if (!sp && !ids.length) return { error: 'Paste a Bilibili channel link (space.bilibili.com/...), a collection link, or video links (bilibili.com/video/BV...).' };
  let title = '', parts = 0, done = 0;
  try {
    if (!sp) {
      title = 'Bilibili videos'; parts = Math.min(ids.length, 100);
      for (const b of ids.slice(0, 100)) { add(bv(await bj('https://api.bilibili.com/x/web-interface/view?bvid=' + b))); done++; }
    } else {
      const mid = sp[1], one = raw.match(/\/lists\/(\d+)(?:[^#]*type=(season|series))?/i);
      if (one) { title = 'Bilibili collection'; parts = 1; await biliList(mid, one[2] || 'season', one[1], add); done++; }
      else {
        const lists: [string, string][] = [];
        for (let pn = 1; pn <= 10; pn++) {
          const d = (await bj(`https://api.bilibili.com/x/polymer/web-space/seasons_series_list?mid=${mid}&page_num=${pn}&page_size=20`))?.items_lists || {};
          for (const s of d.seasons_list || []) if (s.meta?.total) lists.push(['season', String(s.meta.season_id)]);
          for (const s of d.series_list || []) if (s.meta?.total) lists.push(['series', String(s.meta.series_id)]);
          if (pn * 20 >= (d.page?.total || 0)) break;
        }
        if (!lists.length) return { error: 'That Bilibili channel has no collections the site can read. Paste video links (bilibili.com/video/BV...) instead.' };
        title = `Bilibili channel (${lists.length} collections)`; parts = lists.length;
        for (const l of lists) { await biliList(mid, l[0], l[1], add); done++; }
      }
    }
  } catch (e) {
    if (!(e instanceof Refused)) throw e;
    if (!seen.size) return { error: 'Bilibili refused the request (its anti-bot check blocks servers at times). Try again later, or paste the VOD link on the game by hand.' };
    title += ` · Bilibili stopped answering partway, so only ${done} of ${parts} ${parts === 1 ? 'part was' : 'parts were'} read. Run it again later for the rest`;
  }
  return { playlist: 'bilibili', title, videos: [...seen.values()] };
}

Deno.serve(async (req) => {
  const h = cors(req.headers.get('origin'));
  const out = (body: unknown) => new Response(JSON.stringify(body), { headers: { ...h, 'Content-Type': 'application/json' } });
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  try {
    const { playlist } = await req.json().catch(() => ({}));
    const raw = String(playlist || '').trim();
    // Bilibili: a channel (its collections), one collection, or video links. No key needed.
    if (/bilibili\.com|^BV[A-Za-z0-9]{8,}/i.test(raw)) return out(await bili(raw));
    const key = Deno.env.get('YOUTUBE_API_KEY');
    if (!key) return out({ error: 'The YouTube key is not set. Add a secret named YOUTUBE_API_KEY in Supabase > Edge Functions > Secrets.' });
    let id = '', chTitle = '';
    const m = raw.match(/[?&]list=([A-Za-z0-9_-]+)/);
    // a channel link (or @handle): read the channel's uploads playlist, newest first
    const ch = m ? null : raw.match(/youtube\.com\/channel\/(UC[A-Za-z0-9_-]{20,})/i) || raw.match(/^(UC[A-Za-z0-9_-]{20,})$/);
    const hd = m || ch ? null : raw.match(/youtube\.com\/(@[^/?#\s]+)/i) || raw.match(/^(@[^/?#\s]+)$/);
    const un = m || ch || hd ? null : raw.match(/youtube\.com\/(?:c|user)\/([^/?#\s]+)/i);
    if (m) id = m[1];
    else if (ch || hd || un) {
      const look = async (q: Record<string, string>) => {
        const r = await fetch('https://www.googleapis.com/youtube/v3/channels?' + new URLSearchParams({ part: 'snippet,contentDetails', key, ...q }));
        const j = await r.json().catch(() => ({}));
        if (!r.ok) throw new Error(String(j?.error?.message || r.status));
        return j?.items?.[0] || null;
      };
      const name = decodeURIComponent((ch || hd || un)![1]);
      let c = ch ? await look({ id: name }) : hd ? await look({ forHandle: name }) : await look({ forUsername: name });
      if (!c && un) c = await look({ forHandle: '@' + name });
      if (!c) return out({ error: 'That channel was not found. Paste its link, like https://www.youtube.com/@ChannelName' });
      id = c.contentDetails?.relatedPlaylists?.uploads || '';
      chTitle = c.snippet?.title || '';
      if (!id) return out({ error: 'Could not read the videos of that channel.' });
    } else if (/^[A-Za-z0-9_-]{10,}$/.test(raw)) id = raw;
    if (!id) return out({ error: 'Paste a YouTube playlist or channel link, like https://www.youtube.com/playlist?list=PL... or https://www.youtube.com/@ChannelName' });
    const videos: { id: string; title: string; published: string }[] = [];
    let page = '';
    // 50 videos a page, up to 2,000 videos
    for (let i = 0; i < 40; i++) {
      const q = new URLSearchParams({ part: 'snippet,contentDetails', maxResults: '50', playlistId: id, key });
      if (page) q.set('pageToken', page);
      const r = await fetch('https://www.googleapis.com/youtube/v3/playlistItems?' + q);
      const j = await r.json().catch(() => ({}));
      if (!r.ok) {
        const why = j?.error?.errors?.[0]?.reason || '', msg = String(j?.error?.message || r.status);
        if (why === 'playlistNotFound') return out({ error: 'That playlist was not found. It has to be public or unlisted, not private.' });
        if (why === 'quotaExceeded') return out({ error: "YouTube's daily limit was reached. Try again tomorrow." });
        if (/key/i.test(why + ' ' + msg)) return out({ error: 'YouTube refused the key. Check the YOUTUBE_API_KEY secret, and that YouTube Data API v3 is turned on for it.' });
        return out({ error: 'YouTube said: ' + msg });
      }
      for (const it of j.items || []) {
        const s = it.snippet || {}, vid = it.contentDetails?.videoId || s.resourceId?.videoId;
        if (!vid || /^(private|deleted) video$/i.test(s.title || '')) continue;
        videos.push({ id: vid, title: s.title || '', published: it.contentDetails?.videoPublishedAt || s.publishedAt || '' });
      }
      page = j.nextPageToken || '';
      if (!page) break;
    }
    let title = chTitle ? chTitle + ' (channel uploads)' : '';
    if (!title) try {
      const r = await fetch('https://www.googleapis.com/youtube/v3/playlists?' + new URLSearchParams({ part: 'snippet', id, key }));
      title = (await r.json())?.items?.[0]?.snippet?.title || '';
    } catch { /* the title is only for show */ }
    return out({ playlist: id, title, videos });
  } catch (e) {
    return out({ error: 'Could not read the playlist: ' + (e instanceof Error ? e.message : String(e)) });
  }
});
