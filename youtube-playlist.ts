// Supabase Edge Function: youtube-playlist
// Reads the title, link and upload date of every video in a YouTube playlist, so Missing data can match VODs to games.
// Needs a secret named YOUTUBE_API_KEY (Supabase > Edge Functions > Secrets). Only signed-in users of the site can call it.
const ORIGINS = ['https://livvyrpl.github.io'];
const cors = (o: string | null) => ({
  'Access-Control-Allow-Origin': o && (ORIGINS.includes(o) || /^http:\/\/localhost(:\d+)?$/.test(o)) ? o : ORIGINS[0],
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
});

Deno.serve(async (req) => {
  const h = cors(req.headers.get('origin'));
  const out = (body: unknown) => new Response(JSON.stringify(body), { headers: { ...h, 'Content-Type': 'application/json' } });
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  try {
    const key = Deno.env.get('YOUTUBE_API_KEY');
    if (!key) return out({ error: 'The YouTube key is not set. Add a secret named YOUTUBE_API_KEY in Supabase > Edge Functions > Secrets.' });
    const { playlist } = await req.json().catch(() => ({}));
    const raw = String(playlist || '').trim();
    const m = raw.match(/[?&]list=([A-Za-z0-9_-]+)/) || raw.match(/^([A-Za-z0-9_-]{10,})$/);
    if (!m) return out({ error: 'Paste a YouTube playlist link, like https://www.youtube.com/playlist?list=PL...' });
    const id = m[1];
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
    let title = '';
    try {
      const r = await fetch('https://www.googleapis.com/youtube/v3/playlists?' + new URLSearchParams({ part: 'snippet', id, key }));
      title = (await r.json())?.items?.[0]?.snippet?.title || '';
    } catch { /* the title is only for show */ }
    return out({ playlist: id, title, videos });
  } catch (e) {
    return out({ error: 'Could not read the playlist: ' + (e instanceof Error ? e.message : String(e)) });
  }
});
