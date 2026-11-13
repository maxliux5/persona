package assistant

// The size ratchet for the assistant's prompts (docs/assistant/prompts.md "Golden tests", #6881; the proposal's
// step P0, docs/design/proposals/assistant-instructions.md 4a). The shared instructions, the MCP tool descriptions
// and the supervision events grow one rule at a time, and nothing stops a removed manual from coming back; this
// test makes growth a visible decision. It measures the UTF-8 size of every watched piece, compares it with the
// baseline in testdata/prompt_sizes.json and fails when a piece grows past it. Like the Apple token ratchet
// (apple/PersonaTests TokenRatchetTests) the baseline only goes down: a rule that has to grow is shortened or moved
// elsewhere first, and a shrink lowers the baseline in the same PR by running
//
//	PROMPT_SIZE_UPDATE=1 go test ./internal/assistant -run PromptSizeRatchet
//
// which also adds new keys and drops removed ones, but refuses to write a raised value.

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"testing"
)

const promptSizeBaseline = "testdata/prompt_sizes.json"

// promptSizePieces returns the UTF-8 size in bytes of every piece the ratchet watches, keyed by a stable name:
// each "## " section of the assistant_claude_md goldens ("assistant_claude_md.full#<heading>", with the part before
// the first heading as "#head"), each tool of the assistant MCP list ("mcp_tools.assistant#<tool>", the compact
// json.Marshal of the whole tool object: description and input schema both count), and each supervision event
// golden as a whole ("supervise.<event>"). The sizes of one file's sections add up to the file's size.
func promptSizePieces(t *testing.T) map[string]int {
	t.Helper()
	sizes := map[string]int{}
	set := func(key string, size int) {
		if _, dup := sizes[key]; dup {
			t.Fatalf("duplicate prompt size key %q", key)
		}
		sizes[key] = size
	}

	// The shared instructions, one entry per "## " section.
	files, err := filepath.Glob(filepath.Join("testdata", "prompts", "assistant_claude_md.*.golden"))
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range files {
		name := strings.TrimSuffix(filepath.Base(path), ".golden")
		content, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		if len(content) == 0 {
			t.Fatalf("%s is empty", path)
		}
		sectionKeys := []string{name + "#head"}
		sectionStarts := []int{0}
		for lineStart := 0; lineStart < len(content); {
			lineEnd := bytes.IndexByte(content[lineStart:], '\n')
			end := len(content)
			if lineEnd >= 0 {
				end = lineStart + lineEnd
			}
			if line := content[lineStart:end]; bytes.HasPrefix(line, []byte("## ")) {
				sectionKeys = append(sectionKeys, name+"#"+strings.TrimSpace(string(line[3:])))
				sectionStarts = append(sectionStarts, lineStart)
			}
			if lineEnd < 0 {
				break
			}
			lineStart = end + 1
		}
		for i, start := range sectionStarts {
			end := len(content)
			if i+1 < len(sectionStarts) {
				end = sectionStarts[i+1]
			}
			set(sectionKeys[i], end-start)
		}
	}

	// The assistant's MCP tools, one entry per tool object.
	toolsPath := filepath.Join("..", "hub", "testdata", "prompts", "mcp_tools.assistant.golden")
	raw, err := os.ReadFile(toolsPath)
	if err != nil {
		t.Fatal(err)
	}
	dec := json.NewDecoder(bytes.NewReader(raw))
	dec.UseNumber() // numbers re-marshal exactly as written
	var tools []any
	if err := dec.Decode(&tools); err != nil {
		t.Fatalf("%s: %v", toolsPath, err)
	}
	for _, tool := range tools {
		obj, ok := tool.(map[string]any)
		if !ok {
			t.Fatalf("%s: tool is not an object: %T", toolsPath, tool)
		}
		name, _ := obj["name"].(string)
		if name == "" {
			t.Fatalf("%s: tool without a name", toolsPath)
		}
		compact, err := json.Marshal(obj)
		if err != nil {
			t.Fatalf("%s: %v", toolsPath, err)
		}
		set("mcp_tools.assistant#"+name, len(compact))
	}

	// The supervision events, one entry per golden.
	events, err := filepath.Glob(filepath.Join("testdata", "prompts", "supervise.*.golden"))
	if err != nil {
		t.Fatal(err)
	}
	for _, path := range events {
		content, err := os.ReadFile(path)
		if err != nil {
			t.Fatal(err)
		}
		set(strings.TrimSuffix(filepath.Base(path), ".golden"), len(content))
	}
	return sizes
}

func TestPromptSizeRatchet(t *testing.T) {
	baseline := map[string]int{}
	if raw, err := os.ReadFile(promptSizeBaseline); err == nil {
		if err := json.Unmarshal(raw, &baseline); err != nil {
			t.Fatalf("%s: %v", promptSizeBaseline, err)
		}
	} else if !os.IsNotExist(err) {
		t.Fatal(err)
	}
	current := promptSizePieces(t)

	if os.Getenv("PROMPT_SIZE_UPDATE") != "" {
		refused := false
		for key, old := range baseline {
			if cur, ok := current[key]; ok && cur > old {
				t.Errorf("%s grew from %d to %d bytes; the baseline only goes down: shorten or move text elsewhere first, then update it", key, old, cur)
				refused = true
			}
		}
		if refused {
			t.Fatalf("not rewriting %s", promptSizeBaseline)
		}
		added, removed, lowered := 0, 0, 0
		for key, cur := range current {
			switch old, ok := baseline[key]; {
			case !ok:
				added++
				t.Logf("added %s at %d bytes", key, cur)
			case cur < old:
				lowered++
				t.Logf("lowered %s from %d to %d bytes", key, old, cur)
			}
		}
		for key := range baseline {
			if _, ok := current[key]; !ok {
				removed++
				t.Logf("removed %s", key)
			}
		}
		out, err := json.MarshalIndent(current, "", "  ")
		if err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(promptSizeBaseline, append(out, '\n'), 0o644); err != nil {
			t.Fatal(err)
		}
		t.Logf("rewrote %s: %d entries (%d added, %d removed, %d lowered); read the diff before committing it",
			promptSizeBaseline, len(current), added, removed, lowered)
		return
	}

	keys := make([]string, 0, len(current)+len(baseline))
	for key := range current {
		keys = append(keys, key)
	}
	for key := range baseline {
		if _, ok := current[key]; !ok {
			keys = append(keys, key)
		}
	}
	// Sorted so a failure lists the same keys in the same order on every machine.
	sort.Strings(keys)
	for _, key := range keys {
		old, inBaseline := baseline[key]
		cur, inCurrent := current[key]
		switch {
		case !inCurrent:
			t.Errorf("%s is no longer measured; PROMPT_SIZE_UPDATE=1 go test ./internal/assistant -run PromptSizeRatchet rewrites the baseline", key)
		case !inBaseline:
			t.Errorf("%s is new at %d bytes; PROMPT_SIZE_UPDATE=1 go test ./internal/assistant -run PromptSizeRatchet adds it", key, cur)
		case cur > old:
			t.Errorf("%s grew from %d to %d bytes; the baseline only goes down: shorten or move text elsewhere first, then update it", key, old, cur)
		case cur < old:
			t.Logf("%s shrank from %d to %d bytes; PROMPT_SIZE_UPDATE=1 go test ./internal/assistant -run PromptSizeRatchet lowers the baseline", key, old, cur)
		}
	}
}
