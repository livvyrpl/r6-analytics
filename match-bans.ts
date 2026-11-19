// Supabase Edge Function: match-bans
// Reads the operator bans of every map from an official Rainbow Six esports match page (ubisoft.com/esports),
// so the site can fill in op bans for games that have an official match ID. No secrets needed.
const ORIGINS = ['https://livvyrpl.github.io'];
const cors = (o: string | null) => ({
  'Access-Control-Allow-Origin': o && (ORIGINS.includes(o) || /^http:\/\/localhost(:\d+)?$/.test(o)) ? o : ORIGINS[0],
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
});

type Ban = { name?: string; isAttacker?: boolean; roundIndex?: number };

Deno.serve(async (req) => {
  const h = cors(req.headers.get('origin'));
  const out = (body: unknown) => new Response(JSON.stringify(body), { headers: { ...h, 'Content-Type': 'application/json' } });
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  try {
    const { r6 } = await req.json().catch(() => ({}));
    const id = String(r6 || '').trim();
    if (!/^\d+$/.test(id)) return out({ error: 'No official match ID.' });
    const r = await fetch('https://www.ubisoft.com/en-us/esports/rainbow-six/siege/match/' + id, { headers: { 'User-Agent': 'Mozilla/5.0 (compatible; LivAnalytics/1.0)' } });
    if (r.status === 404) return out({ error: 'The official page for match ' + id + ' does not exist.' });
    if (!r.ok) return out({ error: 'The official site answered ' + r.status + '. Try again later.' });
    const html = await r.text();
    const m = html.match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
    if (!m) return out({ error: 'The official page did not have match data.' });
    const data = JSON.parse(m[1])?.props?.pageProps?.pageData || {};
    const match = data.match || {};
    const names = new Map<number, string>();
    const look = (o: unknown) => { if (o && typeof o === 'object') { const x = o as Record<string, unknown>; if (typeof x.id === 'number' && typeof x.name === 'string' && ('logoUrl' in x || 'guid' in x)) names.set(x.id, x.name); Object.values(x).forEach(look); } };
    look(data.teams); look(data);
    const order = (l: Ban[]) => [...l].sort((a, b) => (a.roundIndex ?? 0) - (b.roundIndex ?? 0));
    const games = (match.games || []).map((g: Record<string, any>) => ({
      map: g?.map?.name || '',
      teams: (g.teams || []).map((t: Record<string, any>) => {
        const bans: Ban[] = order(t.operatorBans || []);
        return {
          name: names.get(t.id) || '',
          score: t.score ?? null,
          atk: bans.filter((b) => b.isAttacker).map((b) => b.name || '').filter(Boolean),
          def: bans.filter((b) => b.isAttacker === false).map((b) => b.name || '').filter(Boolean),
        };
      }),
    }));
    return out({ id, teams: (match.teams || []).map((t: Record<string, any>) => names.get(t.id) || ''), games });
  } catch (e) {
    return out({ error: 'Could not read the official page: ' + (e instanceof Error ? e.message : String(e)) });
  }
});
