// Package main is the small program the website runs in the browser.
//
// parse.go holds the logic and works on any platform. main_js.go exposes it to
// the browser, and main_native.go runs it from the command line for testing.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"strconv"
	"strings"

	"github.com/redraskal/r6-dissect/dissect"
	"github.com/rs/zerolog"
	"github.com/rs/zerolog/log"
)

// Result is the JSON returned for one .rec file. When OK is false only Error
// and Warnings are meaningful.
type Result struct {
	OK           bool     `json:"ok"`
	Error        string   `json:"error,omitempty"`
	GameVersion  string   `json:"gameVersion,omitempty"`
	MatchID      string   `json:"matchId,omitempty"`
	Timestamp    string   `json:"timestamp,omitempty"`
	Map          string   `json:"map,omitempty"`
	RoundNumber  int      `json:"roundNumber,omitempty"` // 1 is the first round, matching R01 in the file name
	Teams        []Team   `json:"teams,omitempty"`
	WinningTeam  *int     `json:"winningTeam"` // 0 or 1, null if the replay does not say
	WinCondition string   `json:"winCondition,omitempty"`
	Site         string   `json:"site"` // empty if the replay does not say
	Players      []Player `json:"players,omitempty"`
	Kills        []Kill   `json:"kills,omitempty"`
	Warnings     []string `json:"warnings"`
}

// Team is one side in the round. Score is the match score after this round,
// StartingScore is the match score before it.
type Team struct {
	Name          string `json:"name"`
	Role          string `json:"role"`
	Score         int    `json:"score"`
	StartingScore int    `json:"startingScore"`
	Won           bool   `json:"won"`
}

// Player is one player's line on the scoreboard for this round. Kills, Deaths,
// Assists and Headshots are for this round only. Score is the in-game running
// total for the match so far, because that is what the replay stores.
type Player struct {
	Username   string `json:"username"`
	TeamIndex  int    `json:"teamIndex"`
	Operator   string `json:"operator"`
	OperatorID string `json:"operatorId"` // a string because ids can be too large for JavaScript numbers
	Role       string `json:"role"`
	Kills      int    `json:"kills"`
	Deaths     int    `json:"deaths"`
	Assists    int    `json:"assists"`
	Headshots  int    `json:"headshots"`
	Score      int    `json:"score"`
}

// Kill is one entry in the kill feed. Time is the round clock, counting down.
type Kill struct {
	Killer      string  `json:"killer"`
	Target      string  `json:"target"`
	Time        string  `json:"time"`
	TimeSeconds float64 `json:"timeSeconds"`
	Headshot    bool    `json:"headshot"`
}

// parseReplay turns the bytes of one .rec file into JSON. It never panics.
func parseReplay(data []byte) (out string) {
	warnings := &warningCollector{}
	log.Logger = zerolog.New(warnings).Level(zerolog.WarnLevel)

	defer func() {
		if p := recover(); p != nil {
			out = encode(Result{
				Error:    fmt.Sprintf("The parser could not read this replay: %v", p),
				Warnings: warnings.list(),
			})
		}
	}()

	result, err := parse(data, warnings)
	if err != nil {
		return encode(Result{Error: friendlyError(err), Warnings: warnings.list()})
	}
	return encode(result)
}

func parse(data []byte, warnings *warningCollector) (Result, error) {
	if len(data) == 0 {
		return Result{}, errors.New("the file is empty")
	}
	r, err := dissect.NewReader(bytes.NewReader(data))
	if err != nil {
		return Result{}, err
	}
	if err := r.Read(); err != nil {
		if !dissect.Ok(err) {
			return Result{}, err
		}
		// The fork treats this as success, but it stops processing at this point.
		warnings.add("The replay ended earlier than expected, so some of this round may be missing.")
	}

	h := r.Header
	res := Result{
		OK:          true,
		GameVersion: h.GameVersion,
		MatchID:     h.MatchID,
		Map:         mapName(h.Map, warnings),
		RoundNumber: h.RoundNumber + 1,
		Site:        h.Site,
	}
	if !h.Timestamp.IsZero() {
		res.Timestamp = h.Timestamp.UTC().Format("2006-01-02T15:04:05Z")
	}

	winner := winningTeam(h, warnings)
	if winner >= 0 {
		res.WinningTeam = &winner
		res.WinCondition = string(h.Teams[winner].WinCondition)
	}

	roles := teamRoles(h, warnings)
	for i, t := range h.Teams {
		res.Teams = append(res.Teams, Team{
			Name:          t.Name,
			Role:          roles[i],
			Score:         t.Score,
			StartingScore: t.StartingScore,
			Won:           i == winner,
		})
	}

	res.Players, res.Kills = players(r, roles, warnings)
	if len(res.Players) == 0 {
		warnings.add("No players were found in this replay.")
	}
	if h.Site == "" {
		warnings.add("The site was not found in this replay.")
	}
	res.Warnings = warnings.list()
	return res, nil
}

// winningTeam works from the score change. The fork's own Won flags can mark
// both teams as winners, or team 1 when neither team's score moved.
func winningTeam(h dissect.Header, warnings *warningCollector) int {
	if h.CodeVersion < dissect.Y9S4 {
		won0, won1 := h.Teams[0].Won, h.Teams[1].Won
		if won0 != won1 {
			if won0 {
				return 0
			}
			return 1
		}
		warnings.add("The winner of this round could not be determined.")
		return -1
	}
	gain0 := h.Teams[0].Score - h.Teams[0].StartingScore
	gain1 := h.Teams[1].Score - h.Teams[1].StartingScore
	switch {
	case gain0 > 0 && gain1 <= 0:
		return 0
	case gain1 > 0 && gain0 <= 0:
		return 1
	}
	warnings.add("The winner of this round could not be determined.")
	return -1
}

// teamRoles returns "Attack" or "Defense" for each team. The fork only works
// this out once it has read 10 players, so short-handed rounds use a fallback.
func teamRoles(h dissect.Header, warnings *warningCollector) [2]string {
	roles := [2]string{string(h.Teams[0].Role), string(h.Teams[1].Role)}
	if roles[0] != "" && roles[1] != "" {
		return roles
	}
	for _, p := range h.Players {
		role, known := p.Operator.KnownRole()
		if !known || p.Operator == dissect.Recruit || p.TeamIndex < 0 || p.TeamIndex > 1 {
			continue
		}
		if role == dissect.Attack {
			roles[p.TeamIndex], roles[p.TeamIndex^1] = "Attack", "Defense"
		} else {
			roles[p.TeamIndex], roles[p.TeamIndex^1] = "Defense", "Attack"
		}
		return roles
	}
	warnings.add("Could not work out which team was attacking.")
	return roles
}

// players builds the scoreboard and kill list. It counts kills itself because
// the fork's PlayerStats credits kills by an unrecognised name to the first player.
func players(r *dissect.Reader, roles [2]string, warnings *warningCollector) ([]Player, []Kill) {
	list := make([]Player, 0, len(r.Header.Players))
	index := make(map[string]int, len(r.Header.Players))
	for i, p := range r.Header.Players {
		name, id := operatorName(p.Operator, warnings)
		player := Player{
			Username:   p.Username,
			TeamIndex:  p.TeamIndex,
			Operator:   name,
			OperatorID: id,
		}
		if p.TeamIndex == 0 || p.TeamIndex == 1 {
			player.Role = roles[p.TeamIndex]
		}
		if i < len(r.Scoreboard.Players) {
			player.Assists = int(r.Scoreboard.Players[i].AssistsFromRound)
			player.Score = int(r.Scoreboard.Players[i].Score)
		}
		list = append(list, player)
		index[p.Username] = i
	}

	kills := make([]Kill, 0)
	died := make(map[int]bool)
	find := func(username string) (int, bool) {
		i, ok := index[username]
		if !ok {
			warnings.add(fmt.Sprintf("The kill feed mentions a player who is not in this round: %q", username))
		}
		return i, ok
	}
	for _, u := range r.MatchFeedback {
		switch u.Type {
		case dissect.Kill:
			headshot := u.Headshot != nil && *u.Headshot
			kills = append(kills, Kill{
				Killer:      u.Username,
				Target:      u.Target,
				Time:        u.Time,
				TimeSeconds: u.TimeInSeconds,
				Headshot:    headshot,
			})
			if i, ok := find(u.Username); ok {
				list[i].Kills++
				if headshot {
					list[i].Headshots++
				}
			}
			if i, ok := find(u.Target); ok {
				died[i] = true
			}
		case dissect.Death:
			if i, ok := find(u.Username); ok {
				died[i] = true
			}
		}
	}
	for i := range died {
		list[i].Deaths = 1
	}
	return list, kills
}

func mapName(m dissect.Map, warnings *warningCollector) string {
	name := m.String()
	if strings.HasPrefix(name, "Map(") {
		id := strconv.FormatInt(int64(m), 10)
		warnings.add("This map is not in the parser's table yet, map id " + id + ".")
		return "Unknown (" + id + ")"
	}
	return strings.TrimSuffix(name, "Y10")
}

func operatorName(o dissect.Operator, warnings *warningCollector) (name, id string) {
	id = strconv.FormatUint(uint64(o), 10)
	name = o.String()
	if strings.HasPrefix(name, "Operator(") {
		warnings.add("An operator is not in the parser's table yet, operator id " + id + ".")
		return "Unknown (" + id + ")", id
	}
	return name, id
}

func friendlyError(err error) string {
	if errors.Is(err, dissect.ErrInvalidFile) {
		return "This is not a Rainbow Six replay file."
	}
	if errors.Is(err, io.EOF) || errors.Is(err, io.ErrUnexpectedEOF) {
		return "This replay file is incomplete. It may not have finished copying or downloading."
	}
	return "The parser could not read this replay: " + err.Error()
}

// encode always returns valid JSON, even if the result cannot be converted.
func encode(res Result) string {
	if res.Warnings == nil {
		res.Warnings = []string{}
	}
	b, err := json.Marshal(res)
	if err != nil {
		fallback, _ := json.Marshal(Result{
			Error:    "The result could not be converted to JSON: " + err.Error(),
			Warnings: []string{},
		})
		return string(fallback)
	}
	return string(b)
}

// routineLogMessages are things the fork logs at warning level during every
// normal replay. They say nothing about whether the parse went well.
var routineLogMessages = map[string]bool{
	"scoreboard_kill": true,
}

// warningCollector receives the fork's log output and keeps a short list of
// unique warnings.
type warningCollector struct {
	items []string
}

const maxWarnings = 50

func (w *warningCollector) Write(line []byte) (int, error) {
	var entry map[string]any
	if err := json.Unmarshal(line, &entry); err != nil {
		w.add(strings.TrimSpace(string(line)))
		return len(line), nil
	}
	message, _ := entry["message"].(string)
	if routineLogMessages[message] {
		return len(line), nil
	}
	if username, ok := entry["username"].(string); ok && username != "" {
		message += " (" + username + ")"
	}
	w.add(message)
	return len(line), nil
}

func (w *warningCollector) add(message string) {
	if message == "" || len(w.items) >= maxWarnings {
		return
	}
	for _, existing := range w.items {
		if existing == message {
			return
		}
	}
	w.items = append(w.items, message)
}

func (w *warningCollector) list() []string {
	if w.items == nil {
		return []string{}
	}
	return w.items
}
