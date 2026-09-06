# Third-party attribution

RelaySyntaxHighlighter derives data and test fixtures from **Prism**
(https://prismjs.com), © Lea Verou and contributors, MIT-licensed.

- `Sources/RelaySyntaxHighlighter/Grammars/*.json` are converted from Prism's
  language definitions (`components/prism-*.js`) — see
  `Scripts/convert-grammars.mjs`. Each file records the source `prismVersion`.
- `Tests/RelaySyntaxHighlighterTests/Fixtures/**/*.test` are copied verbatim
  from Prism's test suite (`tests/languages/`).
- `Sources/RelaySyntaxHighlighter/PrismEngine.swift` is a hand-port of Prism's
  tokenizer (`components/prism-core.js`), and `PrismPostProcessor.swift` ports
  Prism's per-language `after-tokenize` hooks.

Prism is pinned in `Scripts/package.json`; `Scripts/sync-prism.sh` regenerates
the vendored data. See `PORTING.md`.

Prism's MIT license text: https://github.com/PrismJS/prism/blob/master/LICENSE
