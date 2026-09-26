// Runbranch — run any branch of any project on a real port.
// Copyright (C) 2026 Alec McLeod
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; without even the
// implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
// See the GNU General Public License for more details:
// <https://www.gnu.org/licenses/>.

package config

import (
	"fmt"
	"strings"
)

// A config used to be bash that the engine sourced. There is no bash on
// Windows, so it is now PARSED, as a strict subset of what bash would accept:
//
//   KEY=value   KEY="value"   KEY='value'   export KEY=...
//   double quotes may span lines and may contain \" \\ \$ and \`
//   $HOME, ${HOME} and a leading ~ expand; nothing else does
//   # comments, whole-line or trailing
//
// Anything else — command substitution, conditionals, other variables, a
// second command on the line — is an error naming the line, never a guess.
// A file that half-applies reports the wrong problem: an unclosed quote in
// the bash engine once reported itself as "sets no REPO".

// Assign is one KEY=value in a file.
type Assign struct {
	Key   string
	Value string
	// Lines the assignment occupies, 0-based and inclusive. A multi-line
	// value spans several.
	Start, End int
	// Indent and export prefix as written, kept when the line is rewritten.
	Lead string
	// The trailing comment on the last line, with the space before it.
	Comment string
}

// SyntaxError is a line the parser will not read.
type SyntaxError struct {
	Line   int // 1-based
	Detail string
}

func (e *SyntaxError) Error() string { return fmt.Sprintf("line %d: %s", e.Line, e.Detail) }

// Parse reads a config. CRLF files are read as if they were LF.
func Parse(content string) ([]Assign, error) {
	p := &parser{s: strings.ReplaceAll(content, "\r\n", "\n")}
	return p.file()
}

type parser struct {
	s    string
	pos  int
	line int // 0-based
}

func (p *parser) eof() bool  { return p.pos >= len(p.s) }
func (p *parser) peek() byte { return p.s[p.pos] }

func (p *parser) errf(line int, format string, a ...any) error {
	return &SyntaxError{Line: line + 1, Detail: fmt.Sprintf(format, a...)}
}

// lineText is line n as written, for quoting in an error.
func (p *parser) lineText(n int) string {
	lines := strings.Split(p.s, "\n")
	if n < len(lines) {
		return strings.TrimSpace(lines[n])
	}
	return ""
}

func (p *parser) skipBlanks() {
	for !p.eof() && (p.peek() == ' ' || p.peek() == '\t') {
		p.pos++
	}
}

func isNameStart(c byte) bool {
	return c == '_' || (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
}
func isNameChar(c byte) bool { return isNameStart(c) || (c >= '0' && c <= '9') }

func (p *parser) file() ([]Assign, error) {
	var out []Assign
	for !p.eof() {
		lineStart := p.pos
		p.skipBlanks()
		if p.eof() {
			break
		}
		switch p.peek() {
		case '\n':
			p.pos++
			p.line++
			continue
		case '#':
			p.toEOL()
			continue
		}
		a, err := p.assignment(lineStart)
		if err != nil {
			return nil, err
		}
		out = append(out, a)
	}
	return out, nil
}

func (p *parser) toEOL() {
	for !p.eof() && p.peek() != '\n' {
		p.pos++
	}
}

func (p *parser) assignment(lineStart int) (Assign, error) {
	a := Assign{Start: p.line}
	if strings.HasPrefix(p.s[p.pos:], "export ") || strings.HasPrefix(p.s[p.pos:], "export\t") {
		p.pos += len("export")
		p.skipBlanks()
	}
	a.Lead = p.s[lineStart:p.pos]

	nameStart := p.pos
	if p.eof() || !isNameStart(p.peek()) {
		return a, p.notAssignment()
	}
	for !p.eof() && isNameChar(p.peek()) {
		p.pos++
	}
	if p.eof() || p.peek() != '=' {
		return a, p.notAssignment()
	}
	a.Key = p.s[nameStart:p.pos]
	p.pos++ // '='

	v, err := p.word()
	if err != nil {
		return a, err
	}
	a.Value = v
	a.End = p.line

	// What may follow a value: nothing, or a comment. `#` only starts a
	// comment at the start of a word, which is why this is checked here and
	// not inside word().
	commentStart := p.pos
	p.skipBlanks()
	if !p.eof() && p.peek() == '#' {
		p.toEOL()
		a.Comment = p.s[commentStart:p.pos]
	} else if !p.eof() && p.peek() != '\n' {
		return a, p.errf(p.line, "%q has more on the line than one assignment; a config can only set KEY=\"value\"", p.lineText(p.line))
	}
	if !p.eof() {
		p.pos++ // '\n'
		p.line++
	}
	return a, nil
}

func (p *parser) notAssignment() error {
	return p.errf(p.line, "%q is not a KEY=\"value\" assignment, and a config cannot run commands", p.lineText(p.line))
}

// word reads one shell word: runs of unquoted text, "double" and 'single'
// quoted parts, up to unquoted whitespace or the end of the line.
func (p *parser) word() (string, error) {
	var b strings.Builder
	first := true
	for !p.eof() {
		c := p.peek()
		switch {
		case c == ' ' || c == '\t' || c == '\n':
			return b.String(), nil
		case c == '"':
			if err := p.double(&b); err != nil {
				return "", err
			}
		case c == '\'':
			start := p.line
			p.pos++
			for {
				if p.eof() {
					return "", p.errf(start, "unexpected end of file while looking for the matching `''")
				}
				c := p.peek()
				p.pos++
				if c == '\'' {
					break
				}
				if c == '\n' {
					p.line++
				}
				b.WriteByte(c)
			}
		case c == '\\':
			p.pos++
			if p.eof() {
				return b.String(), nil
			}
			if p.peek() == '\n' { // a line continuation
				p.pos++
				p.line++
				continue
			}
			b.WriteByte(p.peek())
			p.pos++
		case c == '$':
			if err := p.dollar(&b); err != nil {
				return "", err
			}
		case c == '`':
			return "", p.errf(p.line, "a backtick runs a command, which a config cannot do")
		case c == '~' && first:
			// A leading ~ is the home directory, as bash would have it in an
			// assignment, when it stands alone or before a slash.
			rest := p.s[p.pos+1:]
			if rest == "" || rest[0] == '/' || rest[0] == '\\' || rest[0] == ' ' || rest[0] == '\t' || rest[0] == '\n' {
				b.WriteString(Home)
			} else {
				b.WriteByte('~')
			}
			p.pos++
		case strings.IndexByte(";&|<>()", c) >= 0:
			return "", p.errf(p.line, "%q is shell syntax, and a config can only set KEY=\"value\"", string(c))
		default:
			b.WriteByte(c)
			p.pos++
		}
		first = false
	}
	return b.String(), nil
}

func (p *parser) double(b *strings.Builder) error {
	start := p.line
	p.pos++ // opening quote
	for {
		if p.eof() {
			return p.errf(start, "unexpected end of file while looking for the matching `\"'")
		}
		c := p.peek()
		switch c {
		case '"':
			p.pos++
			return nil
		case '\\':
			// Inside double quotes a backslash escapes only these; before
			// anything else it is a literal backslash, which is what keeps a
			// Windows path such as C:\Users readable.
			if p.pos+1 < len(p.s) {
				n := p.s[p.pos+1]
				switch n {
				case '"', '\\', '$', '`':
					b.WriteByte(n)
					p.pos += 2
					continue
				case '\n':
					p.pos += 2
					p.line++
					continue
				}
			}
			b.WriteByte('\\')
			p.pos++
		case '$':
			if err := p.dollar(b); err != nil {
				return err
			}
		case '`':
			return p.errf(p.line, "a backtick runs a command, which a config cannot do")
		case '\n':
			b.WriteByte('\n')
			p.pos++
			p.line++
		default:
			b.WriteByte(c)
			p.pos++
		}
	}
}

// dollar handles a $: $HOME and ${HOME} expand, a $ that cannot start an
// expansion is literal, and anything else is refused rather than guessed at.
func (p *parser) dollar(b *strings.Builder) error {
	rest := p.s[p.pos+1:]
	switch {
	case strings.HasPrefix(rest, "{HOME}"):
		b.WriteString(Home)
		p.pos += 1 + len("{HOME}")
		return nil
	case strings.HasPrefix(rest, "HOME") && (len(rest) == 4 || !isNameChar(rest[4])):
		b.WriteString(Home)
		p.pos += 1 + len("HOME")
		return nil
	case strings.HasPrefix(rest, "("):
		return p.errf(p.line, "$(...) runs a command, which a config cannot do")
	case rest != "" && (isNameChar(rest[0]) || strings.IndexByte("{@*#?!$-", rest[0]) >= 0):
		end := 1
		for end < len(rest) && isNameChar(rest[end]) {
			end++
		}
		return p.errf(p.line, "$%s is not expanded; only $HOME is (or ~)", strings.TrimPrefix(rest[:end], "{"))
	}
	b.WriteByte('$')
	p.pos++
	return nil
}
