// Supabase Edge Function: match-bans
// Reads a series from its official Rainbow Six esports match page (ubisoft.com/esports) and/or its siege.gg page:
// the map veto in order, the order the maps were played, and every map's operator bans. No secrets needed.
// Body: { r6?: "official match id", gg?: "siege.gg match id" }. The official page is used first, siege.gg fills what it lacks.
const ORIGINS = ['https://livvyrpl.github.io'];
const cors = (o: string | null) => ({
  'Access-Control-Allow-Origin': o && (ORIGINS.includes(o) || /^http:\/\/localhost(:\d+)?$/.test(o)) ? o : ORIGINS[0],
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Vary': 'Origin',
});
const UA = { 'User-Agent': 'Mozilla/5.0 (compatible; LivAnalytics/1.0)' };

type Step = { type: 'ban' | 'pick' | 'decider'; team: string | null; map: string };
type Side = { name: string; atk: string[]; def: string[] };
type Game = { map: string; teams: Side[] };
type Series = { teams: string[]; format: string; veto: Step[]; games: Game[] };
const key = (s: string) => s.toLowerCase().replace(/[^a-z]/g, '');

async function official(id: string): Promise<Series> {
  const r = await fetch('https://www.ubisoft.com/en-us/esports/rainbow-six/siege/match/' + id, { headers: UA });
  if (r.status === 404) throw new Error('The official page for match ' + id + ' does not exist.');
  if (!r.ok) throw new Error('The official site answered ' + r.status + '.');
  const m = (await r.text()).match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) throw new Error('The official page did not have match data.');
  const data = JSON.parse(m[1])?.props?.pageProps?.pageData || {};
  const match = data.match || {};
  const names = new Map<number, string>();
  const look = (o: unknown) => { if (o && typeof o === 'object') { const x = o as Record<string, unknown>; if (typeof x.id === 'number' && typeof x.name === 'string' && ('logoUrl' in x || 'guid' in x)) names.set(x.id, x.name); Object.values(x).forEach(look); } };
  look(data);
  const byRound = (l: any[]) => [...l].sort((a, b) => (a.roundIndex ?? 0) - (b.roundIndex ?? 0));
  const games: Game[] = [...(match.games || [])].sort((a: any, b: any) => (a.index ?? 0) - (b.index ?? 0)).map((g: any) => ({
    map: g?.map?.name || '',
    teams: (g.teams || []).map((t: any) => {
      const bans = byRound(t.operatorBans || []);
      return { name: names.get(t.id) || '', atk: bans.filter((b) => b.isAttacker).map((b) => b.name).filter(Boolean), def: bans.filter((b) => b.isAttacker === false).map((b) => b.name).filter(Boolean) };
    }),
  }));
  const kinds: Record<number, Step['type']> = { 1: 'pick', 2: 'ban', 3: 'decider' };
  const veto: Step[] = [...(match.mapSelections || [])].sort((a: any, b: any) => (a.index ?? 0) - (b.index ?? 0))
    .filter((s: any) => kinds[s.selectionType] && s.mapName)
    .map((s: any) => ({ type: kinds[s.selectionType], team: s.choosingTeam || null, map: s.mapName }));
  const n = match.matchFormatNumberOfGames;
  return { teams: (match.teams || []).map((t: any) => names.get(t.id) || ''), format: n ? 'Bo' + n : '', veto, games };
}

async function siegegg(id: string): Promise<Series> {
  const r = await fetch('https://siege.gg/matches/' + id, { headers: UA });
  if (r.status === 404) throw new Error('siege.gg has no match ' + id + '.');
  if (!r.ok) throw new Error('siege.gg answered ' + r.status + '.');
  const m = (await r.text()).match(/<script[^>]*id="__NUXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  if (!m) throw new Error('The siege.gg page did not have match data.');
  const a: any[] = JSON.parse(m[1]);
  const wrap = new Set(['Reactive', 'ShallowReactive', 'Ref', 'ShallowRef', 'EmptyRef']);
  const res = (i: any, d = 0): any => {
    if (typeof i !== 'number' || d > 12) return i;
    const v = a[i];
    if (Array.isArray(v)) { if (typeof v[0] === 'string' && wrap.has(v[0])) return res(v[1], d + 1); return v.map((x) => res(x, d + 1)); }
    if (v && typeof v === 'object') { const o: any = {}; for (const k in v) o[k] = res(v[k], d + 1); return o; }
    return v;
  };
  const at = a.findIndex((x) => x && typeof x === 'object' && !Array.isArray(x) && 'rosters' in x && 'games' in x && String(res(x.id)) === id);
  if (at < 0) throw new Error('The siege.gg page did not have this match.');
  const match = res(at);
  const names = new Map<number, string>();
  (match.rosters || []).forEach((t: any) => names.set(t.id, t.name));
  const kinds: Record<string, Step['type']> = { BAN: 'ban', PICK: 'pick', DECIDER: 'decider' };
  const vi = a.findIndex((x) => x && typeof x === 'object' && !Array.isArray(x) && 'vetos' in x);
  const veto: Step[] = (vi >= 0 ? res(a[vi].vetos) || [] : [])
    .filter((s: any) => kinds[s.type] && s.map?.name)
    .map((s: any) => ({ type: kinds[s.type], team: s.roster_id != null ? names.get(s.roster_id) || null : null, map: s.map.name }));
  const games: Game[] = (match.games || []).map((g: any) => {
    const bans = [...(g.operator_bans || [])].sort((x: any, y: any) => (x.ban_round ?? 0) - (y.ban_round ?? 0));
    return {
      map: g.map?.name || '',
      teams: [...names.entries()].map(([rid, name]) => {
        const mine = bans.filter((b: any) => b.stats_roster_id === rid && b.operator?.name);
        return { name, atk: mine.filter((b: any) => /att/i.test(b.operator.side)).map((b: any) => b.operator.name), def: mine.filter((b: any) => /def/i.test(b.operator.side)).map((b: any) => b.operator.name) };
      }),
    };
  });
  const picks = veto.filter((s) => s.type !== 'ban').length;
  return { teams: [...names.values()], format: picks ? 'Bo' + picks : '', veto, games };
}

Deno.serve(async (req) => {
  const h = cors(req.headers.get('origin'));
  const out = (body: unknown) => new Response(JSON.stringify(body), { headers: { ...h, 'Content-Type': 'application/json' } });
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  try {
    const body = await req.json().catch(() => ({}));
    const r6 = String(body.r6 || '').trim(), gg = String(body.gg || '').trim();
    if (!/^\d+$/.test(r6) && !/^\d+$/.test(gg)) return out({ error: 'No official or siege.gg match ID.' });
    const notes: string[] = [];
    let a: Series | null = null, b: Series | null = null;
    if (/^\d+$/.test(r6)) { try { a = await official(r6); } catch (e) { notes.push(e instanceof Error ? e.message : String(e)); } }
    const lacks = (s: Series | null) => !s || !s.veto.length || !s.games.length || s.games.some((g) => g.teams.every((t) => !t.atk.length && !t.def.length));
    if (/^\d+$/.test(gg) && lacks(a)) { try { b = await siegegg(gg); } catch (e) { notes.push(e instanceof Error ? e.message : String(e)); } }
    if (!a && !b) return out({ error: notes.join(' ') || 'Nothing could be read.' });
    const main = (a || b)!, alt = a ? b : null;
    // the official page first; siege.gg fills a missing veto, or a map without bans
    const games = main.games.length ? main.games.map((g) => {
      if (g.teams.some((t) => t.atk.length || t.def.length) || !alt) return g;
      const o = alt.games.find((x) => key(x.map) === key(g.map));
      return o ? { ...g, teams: o.teams } : g;
    }) : alt?.games || [];
    return out({
      source: [a && 'Official', b && 'siege.gg'].filter(Boolean).join(' + '),
      teams: main.teams.length ? main.teams : alt?.teams || [],
      format: main.format || alt?.format || '',
      veto: main.veto.length ? main.veto : alt?.veto || [],
      games,
      notes,
    });
  } catch (e) {
    return out({ error: 'Could not read the match: ' + (e instanceof Error ? e.message : String(e)) });
  }
});
