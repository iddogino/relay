# Porting a Prism language

RelaySyntaxHighlighter = a hand-rolled Swift port of Prism's tokenizer
(`PrismEngine.swift`, ported from prism-core.js v1.29) + Prism's language
definitions converted to JSON data + Prism's own per-language test suites
run against the port. Rules and fixtures are vendored, pinned to the
`prismjs` version in `Scripts/package.json` (currently 1.29.0, the last
stable v1 — upstream is effectively frozen).

## Adding a language

1. **Sync rules + fixtures** (requires node; one-time `npm install` happens
   automatically):

   ```sh
   cd RelaySyntaxHighlighter/Scripts
   ./sync-prism.sh <lang>          # prism language id, e.g. "ruby"
   ```

   This converts the final computed `Prism.languages.<lang>` object to
   `Sources/RelaySyntaxHighlighter/Grammars/<lang>.json` (in an isolated
   process — Prism components mutate each other when co-loaded) and vendors
   `tests/languages/<lang>/*.test` from the pinned Prism checkout into
   `Tests/RelaySyntaxHighlighterTests/Fixtures/<lang>/`.

   Conversion `WARN` lines mean constructs that don't serialize (JS
   function patterns, unresolvable stale-object cycles). They are not
   necessarily failures — the fixtures are the arbiter.

2. **Run that language's fixtures**:

   ```sh
   cd RelaySyntaxHighlighter
   PRISM_LANG=<lang> swift test
   ```

   Failures print expected-vs-actual simplified token streams (same format
   as Prism's own runner). `allBundledGrammarPatternsCompile` failing means
   a regex didn't survive JS→ICU translation — a `JSRegex.swift` gap.

3. **Fix until green.** In order of preference:
   - A general translation gap (a JS construct ICU mishandles) → fix
     `JSRegex.translate` so every language benefits.
   - A grammar-specific issue (dropped cycle, function pattern, exotic
     regex) → hand-patch `Grammars/<lang>.json` and document the deviation
     in `Grammars/PATCHES.md` (re-syncing REGENERATES the JSON; patches
     must be re-applied per that file).
   - An engine semantics difference → `PrismEngine.swift` is a line-by-line
     port of matchGrammar; fix against the JS source, never speculatively.

4. **Register the extension** in `SyntaxHighlighter.extensionMap`
   (`Sources/RelaySyntaxHighlighter/SyntaxHighlighter.swift`) so the diff
   tray picks it up by filename.

5. **Full suite + CI**: `swift test` (all languages) locally; the
   `highlighter-linux` CI job runs the same suite on Linux
   (swift-corelibs-foundation's NSRegularExpression is also ICU, but its
   behavior is validated separately for a reason).

## Porting many languages at once

Use the committed workflow script (multi-agent; one agent per language):

```
Workflow tool: { scriptPath: "RelaySyntaxHighlighter/Scripts/port-languages.workflow.js",
                 args: ["ruby", "kotlin", ...] }
```

Each agent syncs, tests, and fixes one language to green under the rules
above, and reports pass counts + any hand-patches. Agents may only touch
their own language's grammar JSON, fixtures, and PATCHES.md — engine/
translator gaps are reported for a follow-up fix, never edited in parallel.

## Version bumps

Update `prismjs` in `Scripts/package.json`, re-run `sync-prism.sh` for
every bundled language (re-applying PATCHES.md), and run the full suite.
`bundledLanguages()` in a debug context lists what's vendored.
