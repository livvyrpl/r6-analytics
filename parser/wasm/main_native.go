//go:build !js

package main

import (
	"fmt"
	"os"
)

// main runs the same parsing code from the command line, for testing:
//
//	go run ./wasm path/to/file.rec
func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: wasm <file.rec>")
		os.Exit(2)
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println(parseReplay(data))
}
