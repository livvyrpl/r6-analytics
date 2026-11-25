package dissect

import (
	"bytes"
	"encoding/binary"
	"fmt"
	"math"
	"sort"
)

// Tracks: where every player was during the round, for the 2D replay.
//
// The decompressed replay is a list of numbered frames (about 30 a second):
// [frame number u32][size u32][size bytes][4 bytes]. The positions come first,
// then a second run of frames (numbered from 0 again) that holds the round clock
// (18 37 46 6C 04 <ms left>) and the kill feed. Both runs use the same frame numbers,
// so each position gets its time from the clock frame with the same number.
//
// A position record is the marker 60 73 85 FE. The 4 bytes 12 before the marker are
// the object it belongs to. The byte after the marker is a flags byte; when 0x80 is set,
// x, y and z follow two bytes later.
//
// Player objects are named in the replay's opening part (before the first frame) in the
// same order as the header's player list.

type TrackPoint struct {
	T float32 `json:"t"` // seconds since the start of prep
	X float32 `json:"x"`
	Y float32 `json:"y"`
	Z float32 `json:"z"`
	// which way the player faces, in degrees in the map's x-y plane (0 is +x, 90 is +y); NaN when not known yet
	Yaw float32 `json:"yaw"`
}

// MarshalJSON writes a point as [t, x, y, z, yaw] with two decimals (yaw a whole degree, left out when not known), to keep rounds small.
func (p TrackPoint) MarshalJSON() ([]byte, error) {
	if p.Yaw != p.Yaw {
		return []byte(fmt.Sprintf("[%.2f,%.2f,%.2f,%.2f]", p.T, p.X, p.Y, p.Z)), nil
	}
	return []byte(fmt.Sprintf("[%.2f,%.2f,%.2f,%.2f,%.0f]", p.T, p.X, p.Y, p.Z, p.Yaw)), nil
}

type PlayerTrack struct {
	Username  string       `json:"username"`
	TeamIndex int          `json:"teamIndex"`
	Points    []TrackPoint `json:"points"`
}

type RoundClock struct {
	PrepSeconds   float32            `json:"prepSeconds"`   // how long prep lasted in the replay
	ActionStart   float32            `json:"actionStart"`   // seconds since prep start when the action phase began
	ActionSeconds float32            `json:"actionSeconds"` // the action timer at its start (usually 180)
	End           float32            `json:"end"`
	Deaths        map[string]float32 `json:"deaths,omitempty"` // seconds since prep start, from the kill feed           // the last point in time with positions
}

type frameRef struct {
	num   uint32
	start int // offset of the frame header
	end   int // offset just past the frame body
}

var positionMarker = []byte{0x60, 0x73, 0x85, 0xFE}
var clockMarker = []byte{0x18, 0x37, 0x46, 0x6C, 0x04}

func u32(b []byte, o int) (uint32, bool) {
	if o < 0 || o+4 > len(b) {
		return 0, false
	}
	return binary.LittleEndian.Uint32(b[o:]), true
}

// chainAt says whether a run of n frames in a row starts at p.
func chainAt(b []byte, p int, n int) bool {
	f, ok := u32(b, p)
	if !ok {
		return false
	}
	q := p
	for i := 0; i < n; i++ {
		s, ok := u32(b, q+4)
		if !ok || s > 1<<20 {
			return false
		}
		r := q + 8 + int(s) + 4
		v, ok := u32(b, r)
		if !ok || v <= f || v > f+64 {
			return false
		}
		q = r
		f = v
	}
	return true
}

// walkFrames finds every frame from the first one on.
func walkFrames(b []byte, from int) []frameRef {
	out := make([]frameRef, 0, 16384)
	p := -1
	for q := from; q+8 < len(b); q++ {
		f, _ := u32(b, q)
		s, _ := u32(b, q+4)
		if f <= 3 && s > 8 && s < 1<<20 && chainAt(b, q, 5) {
			p = q
			break
		}
	}
	if p < 0 {
		return out
	}
	for p+8 <= len(b) {
		f, _ := u32(b, p)
		s, _ := u32(b, p+4)
		end := p + 8 + int(s)
		if end > len(b) || s > 1<<20 {
			break
		}
		out = append(out, frameRef{f, p, end})
		r := end + 4
		if v, ok := u32(b, r); ok && (v == f+1 || (v > f && v <= f+64 && chainAt(b, r, 3))) {
			p = r
			continue
		}
		// lost the chain: first look for the same numbers going on (from inside this frame, in case its size was wrong),
		// then for a new run that starts again from 0
		found := -1
		for q := p + 8; q+8 < len(b); q++ {
			v, _ := u32(b, q)
			if ((v > f && v <= f+400) || (v <= 3 && q >= end)) && chainAt(b, q, 4) {
				found = q
				break
			}
		}
		if found < 0 {
			break
		}
		p = found
	}
	return out
}

func (r *Reader) buildTracks() {
	b := r.b
	if len(b) < 1<<16 {
		return
	}
	frames := walkFrames(b, 0)
	if len(frames) < 100 {
		return
	}
	// split into runs where the numbering starts again
	runOf := make([]int, len(frames))
	run := 0
	for i := 1; i < len(frames); i++ {
		if frames[i].num+16 < frames[i-1].num {
			run++
		}
		runOf[i] = run
	}
	frameIndexAt := func(o int) int {
		i := sort.Search(len(frames), func(i int) bool { return frames[i].start > o }) - 1
		if i < 0 || o >= frames[i].end {
			return -1
		}
		return i
	}
	// the clock: ms left for each frame number
	type tick struct {
		num uint32
		ms  uint32
	}
	ticks := make([]tick, 0, 8192)
	for i := 0; ; {
		k := bytes.Index(b[i:], clockMarker)
		if k < 0 {
			break
		}
		o := i + k
		ms, okm := u32(b, o+5)
		if fi := frameIndexAt(o); fi >= 0 && okm {
			ticks = append(ticks, tick{frames[fi].num, ms})
		}
		i = o + len(clockMarker)
	}
	if len(ticks) < 50 {
		return
	}
	sort.Slice(ticks, func(i, j int) bool { return ticks[i].num < ticks[j].num })
	// prep counts down, then the action timer jumps up and counts down
	actionAt := -1
	for i := 1; i < len(ticks); i++ {
		if ticks[i].ms > ticks[i-1].ms+5000 {
			actionAt = i
			break
		}
	}
	// When the clock was not found from the very start, the missing part is filled in with the usual
	// 45 seconds of prep and 180 of action.
	inAction := ticks[0].ms > 46000
	if inAction {
		actionAt = 0
	}
	// Seconds since prep start at each tick. The timer counts down; when it jumps up (action starts,
	// or the defuser timer after a plant) the count carries on from where it was. A timer of 0 means
	// the round is over and the clock stopped, so those ticks are left out and time runs on by frame number.
	type stamp struct {
		num uint32
		sec float64
		ms  uint32
	}
	stamps := make([]stamp, 0, len(ticks))
	var acc float64
	if ticks[0].num > frames[0].num+60 {
		// seconds per frame number, from the clock itself
		var sum float64
		var cnt uint32
		for i := 1; i < len(ticks); i++ {
			if ticks[i].ms < ticks[i-1].ms && ticks[i].num > ticks[i-1].num && ticks[i-1].ms-ticks[i].ms < 2000 {
				sum += float64(ticks[i-1].ms-ticks[i].ms) / 1000
				cnt += ticks[i].num - ticks[i-1].num
			}
		}
		pf := 1.0 / 30
		if cnt > 0 {
			pf = sum / float64(cnt)
		}
		acc = float64(ticks[0].num-frames[0].num) * pf
	}
	prevMs := ticks[0].ms
	var prepLen float64

	for _, t := range ticks {
		if t.ms == 0 {
			continue
		}
		if t.ms <= prevMs {
			acc += float64(prevMs-t.ms) / 1000
		} else if prepLen == 0 && t.ms > prevMs+5000 {
			prepLen = acc

		}
		prevMs = t.ms
		if len(stamps) > 0 && stamps[len(stamps)-1].num == t.num {
			continue
		}
		stamps = append(stamps, stamp{t.num, acc, t.ms})
	}
	if len(stamps) < 10 {
		return
	}
	perFrame := 1.0 / 30
	if n := len(stamps); n > 10 && stamps[n-1].num > stamps[0].num {
		perFrame = (stamps[n-1].sec - stamps[0].sec) / float64(stamps[n-1].num-stamps[0].num)
	}
	elapsed := func(num uint32) float32 {
		i := sort.Search(len(stamps), func(i int) bool { return stamps[i].num >= num })
		if i == 0 {
			return float32(math.Max(0, stamps[0].sec-float64(stamps[0].num-num)*perFrame))
		}
		if i >= len(stamps) {
			l := stamps[len(stamps)-1]
			return float32(l.sec + float64(num-l.num)*perFrame)
		}
		a, c := stamps[i-1], stamps[i]
		return float32(a.sec + (c.sec-a.sec)*float64(num-a.num)/float64(c.num-a.num))
	}
	// Player bodies. Records with flag 0x80 (position) and 0x08 or 0x10 set, second byte small.
	// Defenders' bodies are there from the start of prep; attackers' bodies appear when the action phase starts.
	// Each team's bodies are named in the replay's opening part in the same order as that team's players.
	first := frames[0].start
	type obj struct {
		id     uint32
		at     int
		count  int
		firstT float32
		firstN uint32
		points []TrackPoint
		lastT  float32
		yaw    float32
	}
	objs := map[uint32]*obj{}
	posRun := -1
	for fi, fr := range frames {
		if posRun >= 0 && runOf[fi] != posRun {
			continue
		}
		body := b[fr.start+8 : fr.end]
		for i := 0; ; {
			k := bytes.Index(body[i:], positionMarker)
			if k < 0 {
				break
			}
			m := fr.start + 8 + i + k
			i += k + len(positionMarker)
			if m-12 < 0 || m+18 > len(b) {
				continue
			}
			fl := b[m+4]
			if fl&0x80 == 0 || fl&0x18 == 0 || b[m+5] > 8 {
				continue
			}
			if z, _ := u32(b, m-8); z != 0 {
				continue
			}
			x := math.Float32frombits(binary.LittleEndian.Uint32(b[m+6:]))
			y := math.Float32frombits(binary.LittleEndian.Uint32(b[m+10:]))
			z := math.Float32frombits(binary.LittleEndian.Uint32(b[m+14:]))
			ax, ay := math.Abs(float64(x)), math.Abs(float64(y))
			if x != x || y != y || z != z || ax > 500 || ay > 500 || math.Abs(float64(z)) > 100 || (ax < 0.05 && ay < 0.05) || (ax != 0 && ax < 1e-6) || (ay != 0 && ay < 1e-6) {
				continue
			}
			if posRun < 0 {
				posRun = runOf[fi]
			}
			id, _ := u32(b, m-12)
			o := objs[id]
			t := elapsed(fr.num)
			if o == nil {
				o = &obj{id: id, at: -1, firstT: t, firstN: fr.num, lastT: -1, yaw: float32(math.NaN())}
				objs[id] = o
			}
			o.count++
			// facing: in the main movement record (flags B8 or DC, then 3) a unit quaternion (x, y, z, w) follows 18 bytes after the flags.
			// Its turn about the up axis, plus 90 degrees, is the way the player faces (checked against running direction).
			if (fl == 0xB8 || fl == 0xDC) && b[m+5] == 3 && m+38 <= len(b) {
				var q [4]float64
				for j := range q {
					q[j] = float64(math.Float32frombits(binary.LittleEndian.Uint32(b[m+22+4*j:])))
				}
				if n := math.Sqrt(q[0]*q[0] + q[1]*q[1] + q[2]*q[2] + q[3]*q[3]); math.Abs(n-1) < 0.02 {
					qx, qy, qz, qw := q[0], q[1], q[2], q[3]
					yaw := math.Atan2(2*(qw*qz+qx*qy), 1-2*(qy*qy+qz*qz))*180/math.Pi + 90
					if yaw > 180 {
						yaw -= 360
					}
					o.yaw = float32(yaw)
				}
			}
			// about 10 points a second is enough to draw
			if o.lastT >= 0 && t < o.lastT+0.1 {
				continue
			}
			o.lastT = t
			o.points = append(o.points, TrackPoint{t, x, y, z, o.yaw})
		}
	}
	// Defenders' bodies are there from the first frames. Attackers' bodies appear together when the
	// action phase starts (some seconds of frames later); bodies that show up later still are not players.
	var def, att, rest []*obj
	minT := float32(math.MaxFloat32)
	for _, o := range objs {
		if o.count >= 40 && o.firstT < minT {
			minT = o.firstT
		}
	}
	for _, o := range objs {
		if o.count < 40 {
			continue
		}
		var key [4]byte
		binary.LittleEndian.PutUint32(key[:], o.id)
		// the order they are named in the replay: in its opening part if there, else where they first come up
		if k := bytes.Index(b[:first], key[:]); k >= 0 {
			o.at = k
		} else {
			o.at = first + bytes.Index(b[first:], key[:])
		}
		if o.firstT <= minT+3 {
			def = append(def, o)
		} else {
			rest = append(rest, o)
		}
	}
	if len(rest) > 0 {
		sort.Slice(rest, func(i, j int) bool { return rest[i].firstT < rest[j].firstT })
		// the attackers' spawn: the first moment several bodies appear within a few seconds of each other
		start := rest[0].firstT
		for i := range rest {
			n := 0
			for j := i; j < len(rest) && rest[j].firstT <= rest[i].firstT+5; j++ {
				n++
			}
			if n >= 3 || n == len(rest)-i {
				start = rest[i].firstT
				break
			}
		}
		for _, o := range rest {
			// late spawns count too, but not something that appears later and is gone within seconds (a gadget)
			life := float32(0)
			if len(o.points) > 0 {
				life = o.points[len(o.points)-1].T - o.firstT
			}
			if o.firstT >= start && (o.firstT <= start+10 || (o.firstT <= start+30 && life > 20)) {
				att = append(att, o)
			}
		}
		if prepLen == 0 {
			prepLen = float64(start)
		}
	}
	// A team can play with 4 (or fewer): each side keeps only as many bodies as it has players listed.
	size := map[TeamRole]int{}
	for _, p := range r.Header.Players {
		if p.TeamIndex >= 0 && p.TeamIndex < len(r.Header.Teams) {
			size[r.Header.Teams[p.TeamIndex].Role]++
		}
	}
	pick := func(l []*obj, k int) []*obj {
		sort.Slice(l, func(i, j int) bool { return l[i].count > l[j].count })
		if k <= 0 || k > 5 {
			k = 5
		}
		if len(l) > k {
			l = l[:k]
		}
		sort.Slice(l, func(i, j int) bool { return l[i].at < l[j].at })
		return l
	}
	def, att = pick(def, size[Defense]), pick(att, size[Attack])
	// When each player died: the frame its kill feed record is in (the timer text is ambiguous after a plant).
	death := map[string]float64{}
	for name, o := range r.killOffset {
		if fi := frameIndexAt(o); fi >= 0 {
			death[name] = float64(elapsed(frames[fi].num))
		}
	}
	roundEnd := stamps[len(stamps)-1].sec
	lastT := func(o *obj) float64 {
		if len(o.points) == 0 {
			return 0
		}
		return float64(o.points[len(o.points)-1].T)
	}
	// Each team's bodies go to its players: the death times decide first, the order in the replay second.
	tracks := make([]PlayerTrack, 0, 10)
	var end float32
	for ti, team := range r.Header.Teams {
		group := def
		if team.Role == Attack {
			group = att
		}
		pl := make([]int, 0, 5)
		for i, p := range r.Header.Players {
			if p.TeamIndex == ti {
				pl = append(pl, i)
			}
		}
		cost := func(oi, pi int) float64 {
			o, name := group[oi], r.Header.Players[pl[pi]].Username
			c := 0.0
			e := lastT(o)
			if d, ok := death[name]; ok {
				c += math.Min(60, math.Abs(e-d))
			} else if e < roundEnd-3 {
				// the kill feed can miss a death, so ending early counts for less than a death that does not match
				c += math.Min(15, roundEnd-3-e)
			}
			return c
		}
		// Every player gets one body or none (left before the round, or disconnected); a body goes to one player at most.
		// Leaving a player without a body costs more than any fit, so bodies are only left over when there are more of them.
		const noBody = 70.0
		best, bestC := make([]int, len(pl)), math.Inf(1)
		perm := make([]int, len(pl))
		used := make([]bool, len(group))
		var try func(k int, c float64, free int)
		try = func(k int, c float64, free int) {
			if c >= bestC {
				return
			}
			if k == len(pl) {
				bestC = c
				copy(best, perm)
				return
			}
			for oi := range group {
				if used[oi] {
					continue
				}
				// the replay names each team in player order: a small cost for every pair that comes out of order
				inv := 0
				for j := 0; j < k; j++ {
					if perm[j] > oi {
						inv++
					}
				}
				used[oi] = true
				perm[k] = oi
				try(k+1, c+cost(oi, k)+0.3*float64(inv), free-1)
				used[oi] = false
			}
			// no body for this player: only worth trying when there are fewer bodies than players left
			if free < len(pl)-k {
				perm[k] = -1
				try(k+1, c+noBody, free)
			}
		}
		try(0, 0, len(group))
		for k := range pl {
			if best[k] < 0 {
				continue
			}
			o := group[best[k]]
			p := r.Header.Players[pl[k]]
			tracks = append(tracks, PlayerTrack{Username: p.Username, TeamIndex: ti, Points: o.points})
			if e := float32(lastT(o)); e > end {
				end = e
			}
		}
	}
	r.Tracks = tracks
	c := RoundClock{End: end}
	if prepLen > 0 {
		c.PrepSeconds = float32(prepLen)
		c.ActionStart = float32(prepLen)
		c.ActionSeconds = 180
		if actionAt > 0 {
			c.ActionSeconds = float32(ticks[actionAt].ms) / 1000
		}
	}
	c.Deaths = map[string]float32{}
	for k, v := range death {
		c.Deaths[k] = float32(v)
	}
	r.Clock = &c
}
