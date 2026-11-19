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
type Side = { name: string; atk: string[]; def: string[]; players?: Record<string, unknown>[]; won_atk?: number | null; won_def?: number | null; won_ot_atk?: number | null; won_ot_def?: number | null; start?: string; ot_start?: string; split?: number | null; score?: number | null };
type Game = { map: string; teams: Side[] };
type Info = { league: string; phase: string; vod: string; replay: string };
type Series = { teams: string[]; format: string; veto: Step[]; games: Game[]; info: Info };
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
      const rs = [...(g.rounds || [])].sort((a: any, b: any) => (a.index ?? 0) - (b.index ?? 0)), reg = rs.filter((x: any) => !x.isOvertime), ot = rs.filter((x: any) => x.isOvertime);
      const won = (l: any[], side: string) => l.filter((x: any) => x.winnerId === t.id && x[side] === t.id).length;
      const sideOf = (x: any) => !x ? '' : x.attackerId === t.id ? 'attack' : x.defenderId === t.id ? 'defense' : '';
      const sides = rs.length ? { won_atk: won(reg, 'attackerId'), won_def: won(reg, 'defenderId'), won_ot_atk: won(ot, 'attackerId'), won_ot_def: won(ot, 'defenderId'), start: sideOf(rs[0]), ot_start: sideOf(ot[0]), split: rs.length >= 6 ? rs.slice(0, 6).filter((x: any) => x.winnerId === t.id).length : null } : {};
      const c = (s: any, k: string) => (s?.[k] && typeof s[k] === 'object' ? s[k].count : null) ?? null;
      const players = [...(t.players || [])].sort((x: any, y: any) => (x.positionIndex ?? 0) - (y.positionIndex ?? 0)).map((p: any) => ({
        name: p.name || '', kills: c(p.stats, 'kills'), deaths: c(p.stats, 'deaths'), headshots: c(p.stats, 'headshots'),
        opening_kills: c(p.stats, 'openingKills'), opening_deaths: c(p.stats, 'openingDeaths'),
        kost: typeof p.stats?.kost === 'number' ? Math.round(p.stats.kost * 100) : null, plants: c(p.stats, 'diffuserPlanted'), clutches: c(p.stats, 'clutch'),
      })).filter((p: any) => p.name);
      return { name: names.get(t.id) || '', atk: bans.filter((b) => b.isAttacker).map((b) => b.name).filter(Boolean), def: bans.filter((b) => b.isAttacker === false).map((b) => b.name).filter(Boolean), players, score: t.score ?? null, ...sides };
    }),
  }));
  const kinds: Record<number, Step['type']> = { 1: 'pick', 2: 'ban', 3: 'decider' };
  const veto: Step[] = [...(match.mapSelections || [])].sort((a: any, b: any) => (a.index ?? 0) - (b.index ?? 0))
    .filter((s: any) => kinds[s.selectionType] && s.mapName)
    .map((s: any) => ({ type: kinds[s.selectionType], team: s.choosingTeam || null, map: s.mapName }));
  const n = match.matchFormatNumberOfGames;
  // league: the championship and the event, without saying a word twice (BLAST R6 Major + Osaka Major = BLAST R6 Major Osaka)
  const ch = String(data.championship?.name || ''), co = String(data.competition?.name || ''), seen = new Set(ch.toLowerCase().split(/\s+/));
  const league = [ch, co.split(/\s+/).filter((w) => !seen.has(w.toLowerCase())).join(' ')].filter(Boolean).join(' ').trim();
  const info = { league, phase: String(data.phase?.name || ''), vod: String(match.youtubeLink || ''), replay: String(match.replayLink || '') };
  return { teams: (match.teams || []).map((t: any) => names.get(t.id) || ''), format: n ? 'Bo' + n : '', veto, games, info };
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
        const rw = g.round_wins_by_roster?.[rid] || g.round_wins_by_roster?.[String(rid)];
        return { name, atk: mine.filter((b: any) => /att/i.test(b.operator.side)).map((b: any) => b.operator.name), def: mine.filter((b: any) => /def/i.test(b.operator.side)).map((b: any) => b.operator.name), won_atk: rw?.atk ?? null, won_def: rw?.def ?? null, score: g.win_roster_id === rid ? g.win_score ?? null : g.loss_roster_id === rid ? g.loss_score ?? null : null };
      }),
    };
  });
  const picks = veto.filter((s) => s.type !== 'ban').length;
  return { teams: [...names.values()], format: picks ? 'Bo' + picks : '', veto, games, info: { league: String(match.competition_full_name || match.competition_name || ''), phase: '', vod: '', replay: '' } };
}

// FINDING THE OFFICIAL MATCH of a game with no ID: the official calendar lists every match of a month with its date and teams.
// The same two teams on the same day (or one day either side, when there is nothing on the day) and only one such match.
const nameCore = (s: string) => String(s || '').toLowerCase().replace(/\b(e-?sports?|gaming|team|club|clan|gg)\b/g, '').replace(/[^a-z0-9]/g, '');
const months = new Map<string, any[]>();
async function calendar(ym: string) {
  if (months.has(ym)) return months.get(ym)!;
  const r = await fetch('https://www.ubisoft.com/en-us/esports/rainbow-six/siege/calendar/' + ym, { headers: UA });
  if (!r.ok) throw new Error('The official calendar answered ' + r.status + '.');
  const m = (await r.text()).match(/<script id="__NEXT_DATA__"[^>]*>([\s\S]*?)<\/script>/);
  const list = m ? (JSON.parse(m[1])?.props?.pageProps?.pageData?.matches || []).map((x: any) => ({ id: String(x.id), date: new Date((x.timestamp || 0) * 1000).toISOString().slice(0, 10), t1: x.team1?.name || '', t2: x.team2?.name || '' })) : [];
  months.set(ym, list);
  return list;
}
async function findOfficial(date: string, a: string[], b: string[]) {
  const d0 = Date.parse(String(date).slice(0, 10) + 'T00:00:00Z');
  if (!d0) throw new Error('No date to look for.');
  const yms = [...new Set([-864e5, 0, 864e5].map((x) => new Date(d0 + x).toISOString().slice(0, 7)))];
  const all = (await Promise.all(yms.map(calendar))).flat();
  const A = [...a.map(nameCore), ...a.map((x) => String(x || ''))].filter(Boolean), B = [...b.map(nameCore), ...b.map((x) => String(x || ''))].filter(Boolean);
  // initials of a name: Titan Esports Club = tec, Four Angry Men = fam (every word, and without words like Esports / Gaming)
  const inits = (s: string) => { const w = String(s || '').toLowerCase().split(/[^a-z0-9]+/).filter(Boolean); const all = w.map((x) => x[0]).join(''), core = w.filter((x) => !/^(e-?sports?|gaming|team|club|clan|gg)$/.test(x)).map((x) => x[0]).join(''); return [all, core].filter((x) => x.length >= 2); };
  const raw = (s: string) => String(s || '').toLowerCase().replace(/[^a-z0-9]/g, '');
  const is = (n: string, l: string[]) => {
    const c = nameCore(n); if (!c) return false;
    if (l.some((x) => x === c || (x.length >= 3 && c.length >= 3 && (x.includes(c) || c.includes(x))))) return true;
    const mine = inits(n), r = raw(n);
    if (l.some((x) => mine.includes(x) || inits(x).includes(r) || inits(x).includes(c))) return true;
    // a short name whose letters come in order in the long one, from its first letter: EDG = EDward Gaming, 4AM = FOUR Angry Men
    const num = (s: string) => s.replace(/1/g, 'one').replace(/2/g, 'two').replace(/3/g, 'three').replace(/4/g, 'four').replace(/5/g, 'five');
    const inOrder = (short: string, long: string) => { if (short.length < 2 || short.length > 5 || long.length <= short.length || short[0] !== long[0]) return false; let i = 0; for (const ch of long) if (ch === short[i]) i++; return i === short.length; };
    const longForm = (s: string) => num(raw(s)), shortForms = (s: string) => [raw(s), String(s || '').toLowerCase().replace(/[^a-z0-9]/g, '').replace(/^(\d)/, (d) => num(d)[0])];
    return l.some((x) => shortForms(n).some((s) => inOrder(s, longForm(x))) || shortForms(x).some((s) => inOrder(s, longForm(n))));
  };
  const near = all.filter((m) => ((is(m.t1, A) && is(m.t2, B)) || (is(m.t1, B) && is(m.t2, A))) && Math.abs(Date.parse(m.date + 'T00:00:00Z') - d0) <= 864e5);
  const exact = near.filter((m) => m.date === String(date).slice(0, 10));
  const pick = exact.length === 1 ? exact[0] : !exact.length && near.length === 1 ? near[0] : null;
  return { id: pick?.id || null, match: pick, choices: near.length };
}

// both pages: the official one first, siege.gg for what it lacks
async function readBoth(r6: string, gg: string) {
  const notes: string[] = [];
  let a: Series | null = null, b: Series | null = null;
  if (/^\d+$/.test(r6)) { try { a = await official(r6); } catch (e) { notes.push(e instanceof Error ? e.message : String(e)); } }
  const lacks = (s: Series | null) => !s || !s.veto.length || !s.games.length || s.games.some((g) => g.teams.every((t) => !t.atk.length && !t.def.length));
  if (/^\d+$/.test(gg) && lacks(a)) { try { b = await siegegg(gg); } catch (e) { notes.push(e instanceof Error ? e.message : String(e)); } }
  if (!a && !b) throw new Error(notes.join(' ') || 'Nothing could be read.');
  const main = (a || b)!, alt = a ? b : null;
  // the official page first; siege.gg fills a missing veto, or a map without bans
  const games = main.games.length ? main.games.map((g) => {
    if (g.teams.some((t) => t.atk.length || t.def.length) || !alt) return g;
    const o = alt.games.find((x) => key(x.map) === key(g.map));
    return o ? { ...g, teams: o.teams } : g;
  }) : alt?.games || [];
  return ({
    source: [a && 'Official', b && 'siege.gg'].filter(Boolean).join(' + '),
    teams: main.teams.length ? main.teams : alt?.teams || [],
    format: main.format || alt?.format || '',
    veto: main.veto.length ? main.veto : alt?.veto || [],
    games,
    info: { league: main.info.league || alt?.info.league || '', phase: main.info.phase || alt?.info.phase || '', vod: main.info.vod || alt?.info.vod || '', replay: main.info.replay || alt?.info.replay || '' },
    notes,
  });
}

Deno.serve(async (req) => {
  const h = cors(req.headers.get('origin'));
  const out = (body: unknown) => new Response(JSON.stringify(body), { headers: { ...h, 'Content-Type': 'application/json' } });
  if (req.method === 'OPTIONS') return new Response('ok', { headers: h });
  try {
    const body = await req.json().catch(() => ({}));
    // { find: { date, a: [names of one team], b: [names of the other] } } gives back the official match ID
    if (body.find) return out(await findOfficial(String(body.find.date || ''), [].concat(body.find.a || []).map(String), [].concat(body.find.b || []).map(String)));
    const r6 = String(body.r6 || '').trim(), gg = String(body.gg || '').trim();
    if (!/^\d+$/.test(r6) && !/^\d+$/.test(gg)) return out({ error: 'No official or siege.gg match ID.' });
    return out(await readBoth(r6, gg));
  } catch (e) {
    return out({ error: 'Could not read the match: ' + (e instanceof Error ? e.message : String(e)) });
  }
});
