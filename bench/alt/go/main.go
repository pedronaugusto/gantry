// The Go toolchain's own readers for what gantry recovers: go/parser lists a
// file's imports (ImportsOnly, as go/build and go list read them) and
// golang.org/x/mod/modfile reads go.mod. Same output rows as bench/ops.
package main

import (
	"fmt"
	"go/parser"
	"go/token"
	"os"
	"time"

	"golang.org/x/mod/modfile"
)

func main() {
	if len(os.Args) != 3 {
		fmt.Fprintln(os.Stderr, "usage: alt-go <workload> <file>")
		os.Exit(2)
	}
	workload, file := os.Args[1], os.Args[2]
	data, err := os.ReadFile(file)
	if err != nil {
		panic(err)
	}
	var count int
	var metric, side string
	var op func() error
	switch workload {
	case "imports/go":
		side, metric = "go-parser", "imports"
		op = func() error {
			f, err := parser.ParseFile(token.NewFileSet(), file, data, parser.ImportsOnly)
			if err == nil {
				count = len(f.Imports)
			}
			return err
		}
	case "manifests/go.mod":
		side, metric = "x-mod-modfile", "dependencies"
		op = func() error {
			f, err := modfile.Parse(file, data, nil)
			if err == nil {
				count = len(f.Require)
			}
			return err
		}
	default:
		fmt.Fprintln(os.Stderr, "unknown workload", workload)
		os.Exit(2)
	}
	row := func(metric string, value any, unit string) { fmt.Printf("%s\t%s\t%s\t%v\t%s\n", side, workload, metric, value, unit) }
	must(op())
	if os.Getenv("BENCH_SMOKE") != "" {
		row("ns_per_op", 0, "ns")
	} else {
		iterations, start := 0, time.Now()
		for iterations < 3 || time.Since(start) < 200*time.Millisecond {
			must(op())
			iterations++
		}
		row("ns_per_op", fmt.Sprintf("%.3f", float64(time.Since(start).Nanoseconds())/float64(iterations)), "ns")
		row("iterations", iterations, "iterations")
	}
	row("source", len(data), "bytes")
	row(metric, count, "count")
}

func must(err error) {
	if err != nil {
		panic(err)
	}
}
