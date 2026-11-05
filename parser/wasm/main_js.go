//go:build js && wasm

package main

import (
	"fmt"
	"syscall/js"
)

// main exposes parseReplay(Uint8Array) to the browser. It returns a JSON string.
func main() {
	js.Global().Set("parseReplay", js.FuncOf(func(_ js.Value, args []js.Value) (out any) {
		// Covers problems before parseReplay starts, such as a wrong argument type.
		defer func() {
			if p := recover(); p != nil {
				out = encode(Result{Error: fmt.Sprintf("The file could not be passed to the parser: %v", p)})
			}
		}()
		if len(args) != 1 {
			return encode(Result{Error: "parseReplay expects the bytes of one .rec file."})
		}
		data := make([]byte, args[0].Get("length").Int())
		js.CopyBytesToGo(data, args[0])
		return parseReplay(data)
	}))
	select {} // keep the program alive so the page can keep calling parseReplay
}
