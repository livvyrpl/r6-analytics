# Replay parser

This folder holds the code that reads Rainbow Six `.rec` replay files in the browser. Files are read on the user's own computer and are never uploaded.

It is a copy of [ImAAhmad/r6-dissect](https://github.com/ImAAhmad/r6-dissect) at commit `58062b0`, under its MIT license (see `LICENSE`). The original README is in that repository.

## What differs from the fork

- `../parser-patch/unknown-operator.patch` adds Noor and stops the parser crashing on operators it doesn't know.
- `../parser-patch/empty-replay-guard.patch` stops a crash on replay files with no data after the header.
- `wasm/` is new. It is the small program the website runs, with one function: `parseReplay(bytes)`, which returns JSON.
- The fork's test replays (`dissect/test`), research exports (`exports/*.json`) and CI files were left out. They added 143 MB and the build doesn't use them.

## How it is rebuilt

You don't need to install anything. Any change inside `parser/` that reaches the `main` branch starts the **Build replay parser** workflow on GitHub. It builds `parser.wasm`, copies Go's matching `wasm_exec.js`, and commits both to `parser-build/`. It takes about two minutes.

To rebuild without changing anything, go to the **Actions** tab, choose **Build replay parser**, then **Run workflow**.

Don't edit `parser.wasm` or `wasm_exec.js` in `parser-build/` by hand. The next build replaces them. `parser-worker.js` and `check.html` in that folder are written by hand and the build leaves them alone.

## Adding a new operator

When the game releases an operator, the site shows them as `Unknown (id)` and a warning gives the id number. Nothing is lost in the meantime.

Edit these two files, using the pencil icon on GitHub if you like:

1. In `dissect/operator_string.go`, add the name to `_extraOperatorNames`:

   ```go
   456757346397: "Noor",
   ```

2. In `dissect/operator_roles.go`, add the role to `_operatorRoles`, using `Attack` or `Defense`:

   ```go
   456757346397: Defense, // Noor
   ```

Commit to `main` and the parser rebuilds itself. To confirm, open `parser-build/check.html` on the live site and load a replay with that operator.

Don't run `go generate` in this folder. It regenerates those files and can overwrite these additions.

## Testing a replay

- **In a browser:** open `parser-build/check.html` on the live site and choose a `.rec` file.
- **On a computer with Go installed:** run `go run ./wasm path/to/file.rec` in this folder. It prints the same JSON.

## If a game update breaks parsing

Operators are the easy case. If an update changes the replay format, every file will show an error or empty results, and the fix has to come from the parser code itself. Check the fork and [the original r6-dissect project](https://github.com/redraskal/r6-dissect) for updates.

## For the page that calls the parser

`parseReplay` returns an error message rather than throwing, including for damaged files. The one exception is the browser running out of memory, which Go can't catch and which stops the program. The calling page must wrap the call in `try/catch` and load a fresh copy of the parser if it fails. Memory used by the parser is not given back to the browser until that copy is discarded.

`score` for each player is the running total for the match, not the points from that round. Kills, deaths, assists and headshots are per round.

The Import page in `index.html` runs the parser through `parser-build/parser-worker.js`, one file at a time, and starts a fresh copy for each match.
