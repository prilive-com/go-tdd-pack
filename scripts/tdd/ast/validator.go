// Command tdd-ast-validator is the v1.8.0 AST helper for the typed
// test-edit exception system. Invoked from
// scripts/tdd/_lib_test_edit_exception.sh via `go run` whenever
// `go` is available; the validator library AND-gates this output
// with the round-1..round-7 regex checks.
//
// Subcommands (each reads a unified diff on stdin):
//
//	import-block-check       --paths a,b,c
//	  Reject any +/- line whose new-file line number falls
//	  outside an `import (...)` block or top-level
//	  `import "x"` declaration in the on-disk file.
//
//	mech-sig-prop-check      --symbols X,Y --paths a,b,c
//	  For paired -/+ assertion lines, reject if the assertion
//	  helper (e.g. `require.Equal`) shape changes between
//	  sides — only call-site arguments may differ.
//
//	compile-fix-scope-check  --symbols X,Y --paths a,b,c
//	  Reject any changed line whose AST identifiers do NOT
//	  include any declared scope symbol (AST identifier match,
//	  not regex word-boundary substring).
//
//	schema-predicate-check   --old-name X --new-name Y --paths a,b,c
//	  Accept ONLY pure renames of `X` to `Y`. Any other
//	  identifier change between - and + sides is rejected.
//
// Each subcommand emits a single-line JSON `Report` on stderr and
// exits 0 (pass), 1 (validation reject), or 2 (hard error /
// malformed input). Stdout is reserved for `--version`.
//
// Honest scope: snippet parsing wraps the diff line in a minimal
// `package _x; func _f() { <line> }` shell so go/parser can
// resolve identifiers + call expressions. Lines that can't be
// parsed as expressions are treated as "no idents found" and
// fall through to the surrounding subcommand's policy.
package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"go/ast"
	"go/parser"
	"go/scanner"
	"go/token"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
)

const Version = "tdd-ast-validator v1.8.0"

type Report struct {
	OK       bool     `json:"ok"`
	Reason   string   `json:"reason"`
	Evidence []string `json:"evidence,omitempty"`
}

func emit(r Report) {
	enc := json.NewEncoder(os.Stderr)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(r)
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: tdd-ast-validator <subcommand> [flags] < diff.patch")
		os.Exit(2)
	}
	cmd := os.Args[1]
	args := os.Args[2:]
	switch cmd {
	case "--version", "-v", "version":
		fmt.Println(Version)
		os.Exit(0)
	case "import-block-check":
		runImportBlockCheck(args, os.Stdin)
	case "mech-sig-prop-check":
		runMechSigPropCheck(args, os.Stdin)
	case "compile-fix-scope-check":
		runCompileFixScopeCheck(args, os.Stdin)
	case "schema-predicate-check":
		runSchemaPredicateCheck(args, os.Stdin)
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand: %s\n", cmd)
		os.Exit(2)
	}
}

// ─── flag parsing ────────────────────────────────────────────────────

type checkArgs struct {
	paths   []string
	symbols []string
	oldName string
	newName string
}

func parseFlags(name string, args []string) checkArgs {
	fs := flag.NewFlagSet(name, flag.ContinueOnError)
	pathsRaw := fs.String("paths", "", "comma-separated paths to check")
	symRaw := fs.String("symbols", "", "comma-separated declared scope symbols")
	oldName := fs.String("old-name", "", "old identifier name (schema-predicate-check)")
	newName := fs.String("new-name", "", "new identifier name (schema-predicate-check)")
	if err := fs.Parse(args); err != nil {
		emit(Report{OK: false, Reason: "flag_parse_error", Evidence: []string{err.Error()}})
		os.Exit(2)
	}
	return checkArgs{
		paths:   splitCSV(*pathsRaw),
		symbols: splitCSV(*symRaw),
		oldName: *oldName,
		newName: *newName,
	}
}

func splitCSV(s string) []string {
	if s == "" {
		return nil
	}
	parts := strings.Split(s, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if p = strings.TrimSpace(p); p != "" {
			out = append(out, p)
		}
	}
	return out
}

// ─── unified-diff parser ─────────────────────────────────────────────

type FileDiff struct {
	Path  string
	Hunks []Hunk
}

type Hunk struct {
	OldStart int
	NewStart int
	Lines    []HunkLine
}

type HunkLine struct {
	Kind    byte // '+', '-', ' '
	Text    string
	OldLine int
	NewLine int
}

func parseUnifiedDiff(r io.Reader) []FileDiff {
	var files []FileDiff
	var cur *FileDiff
	var hunk *Hunk
	var oldLine, newLine int
	sc := bufio.NewScanner(r)
	sc.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for sc.Scan() {
		line := sc.Text()
		switch {
		case strings.HasPrefix(line, "--- "):
			// noop; +++ sets the path
		case strings.HasPrefix(line, "+++ "):
			path := strings.TrimSpace(strings.TrimPrefix(line, "+++ "))
			if i := strings.IndexByte(path, '\t'); i >= 0 {
				path = path[:i]
			}
			path = strings.TrimPrefix(path, "b/")
			files = append(files, FileDiff{Path: path})
			cur = &files[len(files)-1]
			hunk = nil
		case strings.HasPrefix(line, "@@"):
			if cur == nil {
				continue
			}
			os1, ns1 := parseHunkHeader(line)
			cur.Hunks = append(cur.Hunks, Hunk{OldStart: os1, NewStart: ns1})
			hunk = &cur.Hunks[len(cur.Hunks)-1]
			oldLine = os1
			newLine = ns1
		default:
			if cur == nil || hunk == nil || len(line) == 0 {
				continue
			}
			kind := line[0]
			text := line[1:]
			switch kind {
			case '+':
				hunk.Lines = append(hunk.Lines, HunkLine{Kind: '+', Text: text, NewLine: newLine})
				newLine++
			case '-':
				hunk.Lines = append(hunk.Lines, HunkLine{Kind: '-', Text: text, OldLine: oldLine})
				oldLine++
			case ' ':
				hunk.Lines = append(hunk.Lines, HunkLine{Kind: ' ', Text: text, OldLine: oldLine, NewLine: newLine})
				oldLine++
				newLine++
			}
		}
	}
	return files
}

func parseHunkHeader(s string) (oldStart, newStart int) {
	for _, p := range strings.Fields(s) {
		switch {
		case strings.HasPrefix(p, "-") && len(p) > 1:
			oldStart = parseHunkSpec(strings.TrimPrefix(p, "-"))
		case strings.HasPrefix(p, "+") && len(p) > 1:
			newStart = parseHunkSpec(strings.TrimPrefix(p, "+"))
		}
	}
	return
}

func parseHunkSpec(spec string) int {
	if c := strings.IndexByte(spec, ','); c >= 0 {
		spec = spec[:c]
	}
	n, _ := strconv.Atoi(spec)
	return n
}

// filterFilesByPaths returns the subset of `files` whose Path
// corresponds to one of `targets` (per pathMatches). When `targets`
// is empty, returns `files` unchanged. Used by all four AST
// subcommands so a multi-file diff is not misvalidated against an
// unrelated approved exception (v1.8.0 round-5 F1).
func filterFilesByPaths(files []FileDiff, targets []string) []FileDiff {
	if len(targets) == 0 {
		return files
	}
	var out []FileDiff
	for _, fd := range files {
		for _, t := range targets {
			if pathMatches(fd.Path, t) {
				out = append(out, fd)
				break
			}
		}
	}
	return out
}

// pathMatches reports whether the diff's relative path corresponds to
// the validator's target path. v1.8.0 round-5 F2: prefer exact suffix
// match (the diff's path being the tail of the absolute target),
// rejecting the basename-only fallback that previously cross-matched
// `b/x_test.go` against `/tmp/a/x_test.go`. This still allows callers
// to pass project-absolute targets while diffs use project-relative
// paths.
func pathMatches(diffPath, target string) bool {
	if diffPath == "" || target == "" {
		return false
	}
	if diffPath == target {
		return true
	}
	if strings.HasSuffix(target, "/"+diffPath) {
		return true
	}
	cleanDiff := filepath.Clean(diffPath)
	cleanTarget := filepath.Clean(target)
	if cleanDiff == cleanTarget {
		return true
	}
	if strings.HasSuffix(cleanTarget, string(filepath.Separator)+cleanDiff) {
		return true
	}
	return false
}

// ─── snippet helpers ─────────────────────────────────────────────────

// extractIdents parses `snippet` (after stripping leading whitespace)
// inside a minimal func-body shell and returns every Ident.Name in
// source order (with duplicates kept). Returns nil on parse error.
// Use scannerIdents for partial fragments that don't parse.
func extractIdents(snippet string) []string {
	src := "package _x\nfunc _f(){\n" + strings.TrimSpace(snippet) + "\n}\n"
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "", src, parser.AllErrors)
	if err != nil || f == nil {
		return nil
	}
	var out []string
	ast.Inspect(f, func(n ast.Node) bool {
		if id, ok := n.(*ast.Ident); ok && id.Name != "_x" && id.Name != "_f" {
			out = append(out, id.Name)
		}
		return true
	})
	return out
}

// scannerIdents tokenizes `snippet` with go/scanner and returns every
// IDENT token's text. Unlike extractIdents this works on partial Go
// fragments (e.g., `Reconcile(` from a multi-line refactor). Used by
// compile-fix-scope-check to detect scope-symbol tokens on lines that
// don't parse cleanly (v1.8.0 round-3 F3).
func scannerIdents(snippet string) []string {
	toks := scanLineTokens(snippet)
	var out []string
	for _, t := range toks {
		if t.kind == token.IDENT {
			out = append(out, t.text)
		}
	}
	return out
}

// extractTokens returns BOTH idents AND BasicLit values (in source
// order) for a snippet. Used by schema-predicate-check to detect
// literal-value swaps (e.g. `200 -> 201`) that an idents-only
// comparison would miss (v1.8.0 round-1 F1).
func extractTokens(snippet string) []string {
	src := "package _x\nfunc _f(){\n" + strings.TrimSpace(snippet) + "\n}\n"
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "", src, parser.AllErrors)
	if err != nil || f == nil {
		return nil
	}
	var out []string
	ast.Inspect(f, func(n ast.Node) bool {
		switch v := n.(type) {
		case *ast.Ident:
			if v.Name != "_x" && v.Name != "_f" {
				out = append(out, "I:"+v.Name)
			}
		case *ast.BasicLit:
			out = append(out, "L:"+v.Value)
		}
		return true
	})
	return out
}

// extractAssertionHelpers returns the qualified call shapes for
// EVERY CallExpr in `snippet`, in source order. For chained calls
// like `assert.New(t).Equal(want, got)`, both `assert.New` and
// `<chain>.Equal` are returned so callers can compare full helper
// shapes (v1.8.0 round-1 F4: outer-call helper changes were missed
// when only the first Ident-receiver selector was returned).
//
// For each CallExpr.Fun that is a SelectorExpr:
//   - If sel.X is *ast.Ident:           "<X>.<Sel>"           (e.g. "require.Equal")
//   - If sel.X is *ast.CallExpr:        "<chain>.<Sel>"       (e.g. "<chain>.Equal")
//   - If sel.X is *ast.SelectorExpr:    "<receiver>.<Sel>"    (best-effort suffix)
//   - Otherwise:                         "*.<Sel>"             (opaque receiver)
func extractAssertionHelpers(snippet string) []string {
	src := "package _x\nfunc _f(){\n" + strings.TrimSpace(snippet) + "\n}\n"
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, "", src, parser.AllErrors)
	if err != nil || f == nil {
		return nil
	}
	var out []string
	ast.Inspect(f, func(n ast.Node) bool {
		call, ok := n.(*ast.CallExpr)
		if !ok {
			return true
		}
		sel, ok := call.Fun.(*ast.SelectorExpr)
		if !ok {
			return true
		}
		var recvName string
		switch x := sel.X.(type) {
		case *ast.Ident:
			recvName = x.Name
		case *ast.CallExpr:
			recvName = "<chain>"
		case *ast.SelectorExpr:
			recvName = "<sel>"
		default:
			recvName = "*"
		}
		out = append(out, recvName+"."+sel.Sel.Name)
		return true
	})
	return out
}

// extractAssertionHelper retains the v1.7-era single-return signature
// for callers that only need the first qualified helper. New code
// should prefer extractAssertionHelpers (slice) so chained helper
// changes are detected (v1.8.0 round-1 F4).
func extractAssertionHelper(snippet string) string {
	hs := extractAssertionHelpers(snippet)
	if len(hs) == 0 {
		return ""
	}
	return hs[0]
}

// ─── import-block-check ───────────────────────────────────────────────

func runImportBlockCheck(args []string, stdin io.Reader) {
	a := parseFlags("import-block-check", args)
	files := parseUnifiedDiff(stdin)
	for _, target := range a.paths {
		fd, ok := findFileDiff(files, target)
		if !ok {
			continue
		}
		// v1.8.0 round-2 F3: synthesize the NEW file by applying the
		// diff hunks to the on-disk OLD file, parse it with go/parser,
		// then check each + line's new-file line number against the
		// new file's import block ranges. This handles BOTH:
		//   - legitimate top-level import additions (line numbers
		//     don't align with old-file ranges → previous code rejected)
		//   - misplaced imports inside function bodies (parse fails
		//     OR the + line lands outside any new-file import range)
		oldSrc, err := os.ReadFile(target)
		if err != nil {
			// Can't read; abstain (caller AND-gates with regex).
			continue
		}
		oldLines := splitLinesPreserving(string(oldSrc))
		newLines := applyDiff(oldLines, fd.Hunks)
		newSrc := strings.Join(newLines, "\n")
		fset := token.NewFileSet()
		newFile, perr := parser.ParseFile(fset, target, newSrc, parser.ImportsOnly|parser.AllErrors)
		if perr != nil && newFile == nil {
			emit(Report{OK: false, Reason: "synthesized_new_file_parse_failed", Evidence: []string{perr.Error()}})
			os.Exit(1)
		}
		var newRanges [][2]int
		for _, decl := range newFile.Decls {
			gd, ok := decl.(*ast.GenDecl)
			if !ok || gd.Tok != token.IMPORT {
				continue
			}
			startPos := fset.Position(gd.Pos())
			endPos := fset.Position(gd.End())
			newRanges = append(newRanges, [2]int{startPos.Line, endPos.Line})
		}
		// v1.8.0 round-3 F1: also collect OLD file's import block ranges
		// so deletions can be validated against the source position.
		oldRanges, _ := importBlockRanges(target)
		for _, h := range fd.Hunks {
			for _, l := range h.Lines {
				text := strings.TrimSpace(l.Text)
				if text == "" {
					continue
				}
				// v1.8.0 round-6 F3: comments are NOT skipped
				// blanket — Go directives like `//go:build` change
				// compilation semantics. A comment line is allowed
				// only when it lives INSIDE an import block range.
				switch l.Kind {
				case '+':
					if !lineInRanges(l.NewLine, newRanges) {
						emit(Report{OK: false, Reason: "outside_import_block", Evidence: []string{
							fmt.Sprintf("%s:%d (added): %s", target, l.NewLine, text),
						}})
						os.Exit(1)
					}
				case '-':
					if !lineInRanges(l.OldLine, oldRanges) {
						emit(Report{OK: false, Reason: "outside_import_block_deletion", Evidence: []string{
							fmt.Sprintf("%s:%d (deleted): %s", target, l.OldLine, text),
						}})
						os.Exit(1)
					}
				}
			}
		}
	}
	emit(Report{OK: true, Reason: "all_lines_inside_import_block"})
	os.Exit(0)
}

func lineInRanges(line int, ranges [][2]int) bool {
	for _, r := range ranges {
		if line >= r[0] && line <= r[1] {
			return true
		}
	}
	return false
}

// splitLinesPreserving splits `s` on `\n`, returning lines without the
// trailing newline. Behaves identically to strings.Split(s, "\n") — but
// kept as a named helper so the diff applier's intent reads clearly.
func splitLinesPreserving(s string) []string {
	if s == "" {
		return []string{}
	}
	lines := strings.Split(s, "\n")
	// strings.Split on a trailing newline produces an empty trailing
	// element; drop it so length matches the file's line count.
	if len(lines) > 0 && lines[len(lines)-1] == "" {
		lines = lines[:len(lines)-1]
	}
	return lines
}

// applyDiff reconstructs the new-file lines by walking `hunks` against
// the `oldLines` 1-indexed array. Hunks must be in ascending OldStart
// order (standard `diff -u` output is). Lines outside any hunk are
// copied verbatim from old.
func applyDiff(oldLines []string, hunks []Hunk) []string {
	var result []string
	cursor := 1 // 1-indexed; oldLines[cursor-1] is the next old line to consume
	for _, h := range hunks {
		// Copy old lines preceding this hunk.
		for cursor < h.OldStart && cursor-1 < len(oldLines) {
			result = append(result, oldLines[cursor-1])
			cursor++
		}
		for _, l := range h.Lines {
			switch l.Kind {
			case '+':
				result = append(result, l.Text)
			case '-':
				cursor++
			case ' ':
				if cursor-1 < len(oldLines) {
					result = append(result, oldLines[cursor-1])
				} else {
					result = append(result, l.Text)
				}
				cursor++
			}
		}
	}
	// Copy remaining old lines.
	for cursor-1 < len(oldLines) {
		result = append(result, oldLines[cursor-1])
		cursor++
	}
	return result
}

// topOfFileBoundary returns the line number of the first non-package,
// non-import declaration in `path`. Lines <= this boundary are
// considered the "top-of-file region" where new imports may land in a
// file that currently has zero import declarations.
func topOfFileBoundary(path string) int {
	src, err := os.ReadFile(path)
	if err != nil {
		return 0
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, path, src, parser.AllErrors)
	if err != nil && f == nil {
		return 0
	}
	earliestDecl := 0
	for _, decl := range f.Decls {
		pos := fset.Position(decl.Pos())
		if earliestDecl == 0 || pos.Line < earliestDecl {
			earliestDecl = pos.Line
		}
	}
	if earliestDecl == 0 {
		// No decls at all — operator is initializing the file. The
		// "top-of-file region" is unbounded (return a sentinel large
		// enough that any reasonable +/- line falls inside).
		return 1 << 30
	}
	// The boundary is the line strictly BEFORE the first decl.
	return earliestDecl - 1
}

func importBlockRanges(path string) ([][2]int, error) {
	src, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	fset := token.NewFileSet()
	f, err := parser.ParseFile(fset, path, src, parser.ImportsOnly|parser.AllErrors)
	if err != nil && f == nil {
		return nil, err
	}
	var out [][2]int
	for _, decl := range f.Decls {
		gd, ok := decl.(*ast.GenDecl)
		if !ok || gd.Tok != token.IMPORT {
			continue
		}
		startPos := fset.Position(gd.Pos())
		endPos := fset.Position(gd.End())
		out = append(out, [2]int{startPos.Line, endPos.Line})
	}
	return out, nil
}

func findFileDiff(files []FileDiff, target string) (FileDiff, bool) {
	for _, fd := range files {
		if pathMatches(fd.Path, target) {
			return fd, true
		}
	}
	return FileDiff{}, false
}

// ─── mech-sig-prop-check ──────────────────────────────────────────────

func runMechSigPropCheck(args []string, stdin io.Reader) {
	a := parseFlags("mech-sig-prop-check", args)
	files := parseUnifiedDiff(stdin)
	files = filterFilesByPaths(files, a.paths)
	for _, fd := range files {
		for _, h := range fd.Hunks {
			var minus, plus []HunkLine
			for _, l := range h.Lines {
				switch l.Kind {
				case '-':
					minus = append(minus, l)
				case '+':
					plus = append(plus, l)
				}
			}
			n := len(minus)
			if len(plus) < n {
				n = len(plus)
			}
			for i := 0; i < n; i++ {
				// v1.8.0 round-1 F4: compare the FULL helper sequence
				// (every CallExpr selector in source order). For chained
				// calls like `assert.New(t).Equal(...)` -> `.NotEqual(...)`,
				// the outer-call helper change is now detected.
				oldHelpers := extractAssertionHelpers(minus[i].Text)
				newHelpers := extractAssertionHelpers(plus[i].Text)
				if len(oldHelpers) == 0 || len(newHelpers) == 0 {
					continue
				}
				if !equalStringSlices(oldHelpers, newHelpers) {
					emit(Report{OK: false, Reason: "assertion_helper_shape_changed", Evidence: []string{
						"- helpers: " + strings.Join(oldHelpers, ","),
						"+ helpers: " + strings.Join(newHelpers, ","),
					}})
					os.Exit(1)
				}
			}
		}
	}
	emit(Report{OK: true, Reason: "helper_shape_preserved"})
	os.Exit(0)
}

// collapseSpaces normalizes runs of whitespace to a single space and
// trims leading/trailing whitespace. Used by schema-predicate-check
// so formatting-only differences between -/+ don't count as content
// changes.
var spacesRe = regexp.MustCompile(`[[:space:]]+`)

func collapseSpaces(s string) string {
	return strings.TrimSpace(spacesRe.ReplaceAllString(s, " "))
}

// lineToken captures the kind + text of a Go token from go/scanner.
type lineToken struct {
	kind token.Token
	text string
}

// scanLineTokens runs go/scanner over `line` (after stripping leading
// whitespace) inside a minimal func-body shell. Returns the token
// stream excluding EOF and the synthetic shell tokens (`package`,
// `_x`, `func`, `_f`, opening/closing braces). Comments are
// preserved as COMMENT tokens so schema-predicate-check rejects
// rename-shaped changes inside them.
func scanLineTokens(rawLine string) []lineToken {
	src := []byte("package _x\nfunc _f(){\n" + strings.TrimSpace(rawLine) + "\n}\n")
	fset := token.NewFileSet()
	file := fset.AddFile("", -1, len(src))
	var s scanner.Scanner
	s.Init(file, src, nil, scanner.ScanComments)
	var out []lineToken
	for {
		_, tok, lit := s.Scan()
		if tok == token.EOF {
			break
		}
		out = append(out, lineToken{kind: tok, text: lit})
	}
	// Strip the synthetic shell prefix/suffix: `package`, IDENT(_x),
	// SEMICOLON, `func`, IDENT(_f), `(`, `)`, `{`, SEMICOLON ...
	// (varies a bit across Go versions). Walk from start, drop tokens
	// up through and including the first `{`. Then walk from end and
	// drop tokens from the last `}` onward.
	start := 0
	for i, t := range out {
		if t.kind == token.LBRACE {
			start = i + 1
			break
		}
	}
	end := len(out)
	for i := len(out) - 1; i >= 0; i-- {
		if out[i].kind == token.RBRACE {
			end = i
			break
		}
	}
	if start > end {
		return nil
	}
	// Drop trailing SEMICOLON insertions.
	for end > start && out[end-1].kind == token.SEMICOLON {
		end--
	}
	if start > end {
		return nil
	}
	return out[start:end]
}

func equalStringSlices(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

// ─── compile-fix-scope-check ──────────────────────────────────────────

func runCompileFixScopeCheck(args []string, stdin io.Reader) {
	a := parseFlags("compile-fix-scope-check", args)
	if len(a.symbols) == 0 {
		emit(Report{OK: false, Reason: "missing_symbols", Evidence: []string{"--symbols required"}})
		os.Exit(2)
	}
	symSet := make(map[string]bool, len(a.symbols))
	for _, s := range a.symbols {
		symSet[s] = true
	}
	files := parseUnifiedDiff(stdin)
	files = filterFilesByPaths(files, a.paths)
	for _, fd := range files {
		for _, h := range fd.Hunks {
			// v1.8.0 round-3 F3: hunk-level scope. First pass: does
			// ANY changed line in this hunk touch a declared symbol?
			// If yes, syntactically-trivial (operators-only / paren-
			// closer) changed lines in the same hunk are accepted.
			// Second pass: enforce per-line scope-use, with the
			// trivial-line carve-out applied.
			hunkHasScopedChange := false
			for _, l := range h.Lines {
				if l.Kind != '+' && l.Kind != '-' {
					continue
				}
				text := strings.TrimSpace(l.Text)
				if text == "" {
					continue
				}
				// v1.8.0 round-7 F2: comments are NOT skipped — Go
				// directives (//go:build, //go:generate) are
				// semantic. Treat them as off-scope unless they
				// contain a declared scope symbol.
				// Use scanner-based ident extraction so partial
				// fragments like `Reconcile(` count.
				for _, id := range scannerIdents(text) {
					if symSet[id] {
						hunkHasScopedChange = true
						break
					}
				}
				if hunkHasScopedChange {
					break
				}
			}
			for _, l := range h.Lines {
				if l.Kind != '+' && l.Kind != '-' {
					continue
				}
				text := strings.TrimSpace(l.Text)
				if text == "" {
					continue
				}
				// v1.8.0 round-7 F2: see above — comments must pass
				// the scoped-symbol check too.
				idents := scannerIdents(text)
				if len(idents) == 0 {
					// Punctuation-only fragment. Allow when hunk has
					// a scoped change (closer line of a multi-line
					// refactor). Reject otherwise.
					if isPunctuationOnly(text) && hunkHasScopedChange {
						continue
					}
					emit(Report{OK: false, Reason: "unparseable_or_no_idents", Evidence: []string{
						"line: " + text,
					}})
					os.Exit(1)
				}
				hit := false
				for _, id := range idents {
					if symSet[id] {
						hit = true
						break
					}
				}
				if !hit {
					// v1.8.0 round-5 F3: NO carve-out for off-scope
					// IDENT or LITERAL lines, even within a hunk that
					// has a scoped change. A line carrying an
					// off-scope identifier (`DangerousFlag`) or
					// off-scope literal (`"prod"`) cannot be
					// distinguished from a malicious smuggled-in
					// change at this layer. Operator must split such
					// changes into a separate non-exception edit.
					emit(Report{OK: false, Reason: "scope_symbol_not_used", Evidence: []string{
						"line: " + text,
						"identifiers: " + strings.Join(idents, ","),
					}})
					os.Exit(1)
				}
			}
		}
	}
	emit(Report{OK: true, Reason: "all_changes_use_declared_symbol"})
	os.Exit(0)
}

// isPunctuationOnly reports whether `text` contains only Go-syntax
// operators and punctuation (no identifiers, no literals, no
// keywords). Used for the multi-line refactor closer carve-out in
// compile-fix-scope-check (v1.8.0 round-3 F3).
var punctOnlyRe = regexp.MustCompile(`^[(){}\[\];,.&|+\-*/%<>=!?:^~\\\s]*$`)

func isPunctuationOnly(text string) bool {
	return text != "" && punctOnlyRe.MatchString(text)
}

// isArgContinuation reports whether `text` is a simple
// argument-continuation line: only IDENT, BasicLit, and punctuation
// tokens (no LPAREN, LBRACE, KEYWORD). Used by compile-fix-scope-check
// for multi-line scoped-call refactors where each argument lives on
// its own line (v1.8.0 round-4 F2 carve-out).
func isArgContinuation(text string) bool {
	toks := scanLineTokens(text)
	if len(toks) == 0 {
		return false
	}
	for _, t := range toks {
		switch t.kind {
		case token.LPAREN, token.LBRACE, token.LBRACK:
			return false
		}
		if t.kind.IsKeyword() {
			return false
		}
	}
	return true
}

// ─── schema-predicate-check ───────────────────────────────────────────

func runSchemaPredicateCheck(args []string, stdin io.Reader) {
	a := parseFlags("schema-predicate-check", args)
	if a.oldName == "" || a.newName == "" {
		emit(Report{OK: false, Reason: "missing_old_or_new_name"})
		os.Exit(2)
	}
	files := parseUnifiedDiff(stdin)
	files = filterFilesByPaths(files, a.paths)
	for _, fd := range files {
		for _, h := range fd.Hunks {
			var minus, plus []HunkLine
			for _, l := range h.Lines {
				switch l.Kind {
				case '-':
					minus = append(minus, l)
				case '+':
					plus = append(plus, l)
				}
			}
			// v1.8.0 round-1 F1: reject UNMATCHED +/- lines (codex F1).
			// A schema rename should be a strict 1:1 line replacement.
			if len(minus) != len(plus) {
				emit(Report{OK: false, Reason: "non_rename_unmatched_lines", Evidence: []string{
					fmt.Sprintf("- count: %d, + count: %d", len(minus), len(plus)),
				}})
				os.Exit(1)
			}
			n := len(minus)
			// v1.8.0 round-3 F2: tokenize each side with go/scanner
			// (which preserves operators, punctuation, comments, and
			// distinguishes IDENT from STRING/INT literals). The
			// transform is "pure rename" iff for every token position:
			//   - token kind is identical AND
			//   - token text is identical, OR (kind == IDENT AND old
			//     text == oldName AND new text == newName).
			// Renames inside string literals or comments are rejected
			// because their token kind is STRING or COMMENT (not IDENT).
			renameSeen := false
			for i := 0; i < n; i++ {
				oldToks := scanLineTokens(minus[i].Text)
				newToks := scanLineTokens(plus[i].Text)
				if len(oldToks) != len(newToks) {
					emit(Report{OK: false, Reason: "non_rename_token_count_mismatch", Evidence: []string{
						fmt.Sprintf("- %d tokens, + %d tokens", len(oldToks), len(newToks)),
						"- " + strings.TrimSpace(minus[i].Text),
						"+ " + strings.TrimSpace(plus[i].Text),
					}})
					os.Exit(1)
				}
				for j := range oldToks {
					ot, nt := oldToks[j], newToks[j]
					if ot.kind != nt.kind {
						emit(Report{OK: false, Reason: "non_rename_token_kind_changed", Evidence: []string{
							fmt.Sprintf("position %d: %s(%q) -> %s(%q)", j, ot.kind, ot.text, nt.kind, nt.text),
						}})
						os.Exit(1)
					}
					if ot.text == nt.text {
						// v1.8.0 round-7 F1: a position where both
						// sides still hold the OLD name is a partial
						// rename — reject.
						if ot.kind == token.IDENT && ot.text == a.oldName {
							emit(Report{OK: false, Reason: "partial_rename_oldname_remains", Evidence: []string{
								fmt.Sprintf("position %d: %s still on both sides (must be renamed to %s)", j, a.oldName, a.newName),
								"- " + strings.TrimSpace(minus[i].Text),
								"+ " + strings.TrimSpace(plus[i].Text),
							}})
							os.Exit(1)
						}
						continue
					}
					// Texts differ. Allowed only when both are IDENT
					// AND old.text == oldName AND new.text == newName.
					if ot.kind == token.IDENT && ot.text == a.oldName && nt.text == a.newName {
						renameSeen = true
						continue
					}
					emit(Report{OK: false, Reason: "non_rename_change_detected", Evidence: []string{
						fmt.Sprintf("position %d (%s): %q -> %q", j, ot.kind, ot.text, nt.text),
						"- " + strings.TrimSpace(minus[i].Text),
						"+ " + strings.TrimSpace(plus[i].Text),
					}})
					os.Exit(1)
				}
			}
			if n > 0 && !renameSeen {
				emit(Report{OK: false, Reason: "non_rename_no_actual_rename_seen", Evidence: []string{
					fmt.Sprintf("declared rename: %s -> %s; no occurrences renamed", a.oldName, a.newName),
				}})
				os.Exit(1)
			}
		}
	}
	emit(Report{OK: true, Reason: "pure_rename_only"})
	os.Exit(0)
}

// isPureTokenRename returns (allowed, sawRename) where:
//   - allowed: true iff every position differs only by oldTok -> newTok.
//   - sawRename: true iff at least one position WAS oldTok -> newTok.
//
// Tokens are ident-or-literal-encoded (e.g. "I:Foo" / "L:200"). Literal
// changes (e.g. "L:200" -> "L:201") are never accepted as renames.
func isPureTokenRename(old, new []string, oldTok, newTok string) (bool, bool) {
	if len(old) != len(new) {
		return false, false
	}
	sawRename := false
	for i := range old {
		switch {
		case old[i] == oldTok:
			if new[i] != newTok {
				return false, sawRename
			}
			sawRename = true
		case old[i] != new[i]:
			return false, sawRename
		}
	}
	return true, sawRename
}

// isPureRename retained for callers expecting the v1.7-era ident-only
// signature. New code should prefer isPureTokenRename.
func isPureRename(old, new []string, oldName, newName string) bool {
	if len(old) != len(new) {
		return false
	}
	for i := range old {
		switch {
		case old[i] == oldName:
			if new[i] != newName {
				return false
			}
		case old[i] != new[i]:
			return false
		}
	}
	return true
}
