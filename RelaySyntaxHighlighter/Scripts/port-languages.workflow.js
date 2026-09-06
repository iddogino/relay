// Multi-agent porting workflow for Prism languages — see PORTING.md.
// Invoke via the Workflow tool with scriptPath pointing at this file and
// args = an array of prism language ids, e.g. ["ruby", "kotlin"].
// One agent per language: sync → run that language's vendored Prism
// fixture suite → fix to green under the PORTING.md rules → report.
export const meta = {
  name: 'port-prism-languages',
  description: 'Port Prism language grammars: per-language agent fixes its fixture suite to green',
  phases: [{ title: 'Port', detail: 'one agent per language' }],
}

const PKG = '/Users/iddogino/Dropbox/Relay/RelaySyntaxHighlighter'

const REPORT = {
  type: 'object',
  required: ['language', 'total', 'passing', 'failing', 'patches', 'engineGaps', 'notes'],
  properties: {
    language: { type: 'string' },
    total: { type: 'number', description: 'fixture count for this language' },
    passing: { type: 'number' },
    failing: { type: 'number', description: 'MUST be 0 on success' },
    patches: {
      type: 'array',
      items: {
        type: 'object',
        required: ['rule', 'change', 'reason'],
        properties: {
          rule: { type: 'string' },
          change: { type: 'string' },
          reason: { type: 'string' },
        },
      },
    },
    engineGaps: {
      type: 'array',
      items: { type: 'string' },
      description: 'suspected PrismEngine/JSRegex defects (NOT edited), with evidence',
    },
    notes: { type: 'string' },
  },
}

const langs = Array.isArray(args) ? args : []
if (langs.length === 0) {
  throw new Error('pass args: ["<prism language id>", ...]')
}

log(`porting ${langs.length} language(s): ${langs.join(', ')}`)

const results = await pipeline(
  langs,
  (lang) =>
    agent(
      `You are porting the Prism language "${lang}" to RelaySyntaxHighlighter, a Swift port of
Prism's tokenizer that runs Prism's own per-language test fixtures. Work in ${PKG}.
Read ${PKG}/PORTING.md first — it defines the process and the fix-preference order.

SETUP (may already be done — check before redoing):
- Grammar: Sources/RelaySyntaxHighlighter/Grammars/${lang}.json. If missing, run:
  cd ${PKG}/Scripts && PRISM_CLONE=/Users/iddogino/.claude/jobs/e8078a22/tmp/prism-src ./sync-prism.sh ${lang}
- Fixtures: Tests/RelaySyntaxHighlighterTests/Fixtures/${lang}/*.test (same sync vendors them).

RUN THE SUITE (always use your own scratch dir — other agents build concurrently):
  cd ${PKG} && PRISM_LANG=${lang} swift test --scratch-path .scratch/${lang}
Failures print expected-vs-actual simplified token streams. The "allBundledGrammarPatternsCompile"
test failing on a ${lang} pattern means the JS regex didn't survive translation to ICU.

GOAL: that command fully green — every ${lang} fixture passing and no compile failures.

HARD RULES:
- Fixtures are the ground truth. NEVER edit anything under Fixtures/.
- You may ONLY edit: Grammars/${lang}.json, and Grammars/PATCHES.md (create/append).
- NEVER edit Sources/*.swift, the test harness, or any other language's files. If you
  conclude the defect is in PrismEngine.swift or JSRegex.swift (engine semantics or a
  JS→ICU translation gap that would affect multiple languages), capture it in engineGaps
  with concrete evidence (pattern, input, expected vs actual) and move on — another pass
  fixes engine gaps centrally. If an engine gap blocks some fixtures, report those in
  "failing" honestly.

GRAMMAR JSON NOTES:
- Rules are ORDERED (Prism semantics). Patterns are JS-dialect regex sources translated
  to ICU at load (JSRegex.swift handles \\d/\\w/[^]/bare-[ in classes).
- {"$language": "name"} = lazy reference to another bundled grammar (aliases like "js"
  are canonicalized to "javascript"). {"$language": null} = a cycle the converter
  dropped — replacing null with the right language name (often the language itself or
  its base language) is frequently the whole fix.
- Every hand-edit to the JSON must be recorded in Grammars/PATCHES.md as:
  "## <language>\\n- rule <name>: <what changed> — <why> (re-apply after re-sync)".
- Keep edits minimal and semantics-faithful: the aim is Prism's exact tokenization,
  not merely making tests pass. Compare against the JS definition in
  /Users/iddogino/.claude/jobs/e8078a22/tmp/prism-src/components/prism-${lang}.js when in doubt.

When green (or blocked by a reported engine gap), fill the report: total/passing/failing
from the final run, every PATCHES.md entry you added under patches, engine suspicions
under engineGaps, and anything a future porter should know under notes.`,
      { label: `port:${lang}`, phase: 'Port', model: 'opus', schema: REPORT }
    ),
)

const done = results.filter(Boolean)
log(`${done.filter(r => r.failing === 0).length}/${langs.length} languages fully green`)
return done
