// Converts Prism language definitions to the JSON grammar format consumed
// by RelaySyntaxHighlighter's engine.
//
//   node convert-grammars.mjs <lang> [<lang> ...]
//
// Writes ../Sources/RelaySyntaxHighlighter/Grammars/<lang>.json for each.
//
// How it works: loads prismjs (pinned in package.json) with loadLanguages,
// which resolves component dependency order and applies every insertBefore/
// languages.extend mutation. We then serialize the FINAL computed
// Prism.languages[lang] object, so each JSON file is self-contained — no
// runtime knowledge of Prism's inheritance is needed.
//
// Cycles (e.g. javascript → template-string → interpolation → javascript)
// are broken by object identity: any nested grammar object that IS a
// registered language is emitted as {"$language": "<name>"} and resolved
// lazily by the engine's GrammarStore. Non-language cycles are emitted as
// {"$language": null} with a warning — a porting agent must patch by hand.
//
// Functions inside definitions (rare) can't be serialized; they're emitted
// as {"$unsupported": "function"} with a warning and must be hand-ported.

import { createRequire } from 'node:module';
import { writeFileSync, mkdirSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const scriptDir = dirname(fileURLToPath(import.meta.url));
const outDir = join(scriptDir, '..', 'Sources', 'RelaySyntaxHighlighter', 'Grammars');

const langs = process.argv.slice(2);
if (langs.length === 0) {
  console.error('usage: node convert-grammars.mjs <lang> [<lang> ...]');
  process.exit(1);
}

// Load a FRESH Prism core (not `require('prismjs')`, which bundles
// markup/css/clike/javascript) then pull in only the requested languages
// and their declared dependencies. This matters: co-loading javascript
// mutates clike's shared `class-name` object in place, so a bundle load
// corrupts clike even when converting it alone.
const Prism = require('prismjs/components/prism-core.js');
global.Prism = Prism;
const loadLanguages = require('prismjs/components/index.js');
loadLanguages(langs);
const prismVersion = require('prismjs/package.json').version;

// Alias → canonical id, from Prism's own registry (e.g. js → javascript,
// ts → typescript). Refs are always emitted under canonical ids so they
// resolve against the bundled grammar files.
const components = require('prismjs/components.json');
const aliasToCanonical = new Map();
for (const [id, entry] of Object.entries(components.languages)) {
  if (id === 'meta' || typeof entry !== 'object') continue;
  const aliases = entry.alias == null ? [] : [].concat(entry.alias);
  for (const alias of aliases) aliasToCanonical.set(alias, id);
}
const canonical = (name) => aliasToCanonical.get(name) ?? name;

// name → object identity map for $language refs. Built AFTER loading so
// extended/mutated grammars are matched by their final identity. Note that
// insertBefore REPLACES language objects, so a nested `inside` reference
// captured before a later insertBefore can identity-match only an alias
// entry — canonical(name) papers over exactly that.
const languageByObject = new Map();
for (const [name, value] of Object.entries(Prism.languages)) {
  if (typeof value === 'object' && value !== null && !languageByObject.has(value)) {
    languageByObject.set(value, canonical(name));
  }
}

// Structural fingerprint → canonical language, for recognizing DEEP CLONES.
// `Prism.languages.extend('markup', clone(javascript))` (jsx/tsx and other
// embedders) produces fresh objects that share no identity with the
// registered grammar but are content-identical, so identity alone inlines
// them and loses their internal cycles. A fingerprint of a grammar's own
// token names plus each first pattern's source distinguishes languages
// reliably; a clone matches its origin and gets emitted as a ref instead.
function fingerprint(g) {
  const parts = [];
  for (const [name, value] of Object.entries(g)) {
    if (name === 'rest' || value == null) continue;
    const first = Array.isArray(value) ? value[0] : value;
    let sig = '';
    if (first instanceof RegExp) sig = first.source;
    else if (first && first.pattern instanceof RegExp) sig = first.pattern.source;
    else if (typeof first === 'function') sig = '<fn>';
    parts.push(name + '=' + sig);
  }
  return parts.join('');
}
const langByFingerprint = new Map();
const ambiguousFingerprints = new Set();
for (const [name, value] of Object.entries(Prism.languages)) {
  if (typeof value !== 'object' || value === null) continue;
  const canon = canonical(name);
  if (canon !== name) continue; // fingerprint each language once, by canonical id
  const fp = fingerprint(value);
  if (langByFingerprint.has(fp) && langByFingerprint.get(fp) !== canon) {
    ambiguousFingerprints.add(fp); // never guess between two languages
  } else {
    langByFingerprint.set(fp, canon);
  }
}
function languageRefFor(g) {
  const byId = languageByObject.get(g);
  if (byId !== undefined) return byId;
  const fp = fingerprint(g);
  if (ambiguousFingerprints.has(fp)) return undefined;
  return langByFingerprint.get(fp);
}

let warnings = [];

function convertRegex(re) {
  return { pattern: re.source, flags: re.flags.replace(/[gy]/g, '') };
}

// One pattern variant → serializable object. `stack` is the ancestor set
// of the enclosing convertGrammar branch — threaded through so cycles that
// hop grammar → pattern.inside → grammar are still detected.
function convertPattern(p, path, stack) {
  if (p instanceof RegExp) return convertRegex(p);
  if (typeof p === 'function') {
    warnings.push(`${path}: function pattern (unsupported)`);
    return { $unsupported: 'function' };
  }
  const out = convertRegex(p.pattern);
  if (p.lookbehind) out.lookbehind = true;
  if (p.greedy) out.greedy = true;
  if (p.alias) out.alias = Array.isArray(p.alias) ? p.alias : [p.alias];
  if (p.inside) out.inside = convertGrammar(p.inside, `${path}.inside`, stack);
  return out;
}

// A grammar object → {rules: [...], rest?: ref}. `stack` carries the
// ancestor objects of this serialization branch for cycle detection;
// `isRoot` marks the top-level object of the language being converted
// (which must serialize inline, not as a self-reference).
function convertGrammar(g, path, stack, isRoot = false) {
  // Nested reference to a whole language (by identity or as a deep clone) →
  // $language ref. Also breaks cycles, e.g. javascript → template-string →
  // interpolation → javascript.
  if (!isRoot) {
    const langName = languageRefFor(g);
    if (langName !== undefined) return { $language: langName };
  }
  if (stack.has(g)) {
    warnings.push(`${path}: non-language cycle (needs hand-patching)`);
    return { $language: null };
  }
  stack.add(g);
  const out = { rules: [] };
  for (const [name, value] of Object.entries(g)) {
    if (value == null) continue;
    if (name === 'rest') {
      const restLang = languageRefFor(value);
      if (restLang !== undefined) {
        out.rest = { $language: restLang };
      } else {
        // Inline rest grammar: merge its rules at the end, like tokenize().
        const inline = convertGrammar(value, `${path}.rest`, stack);
        if (inline.rules) {
          out.rules.push(...inline.rules);
        } else if ('$language' in inline) {
          // Includes the null-cycle case: leave a VISIBLE {$language:null}
          // marker rather than silently dropping, so a porter auditing the
          // JSON for nulls can see something is missing.
          out.rest = inline;
          if (inline.$language === null) {
            warnings.push(`${path}.rest: unresolvable rest cycle (marked null)`);
          }
        } else {
          warnings.push(`${path}.rest: unresolvable rest reference (dropped)`);
        }
      }
      continue;
    }
    const variants = Array.isArray(value) ? value : [value];
    out.rules.push({
      name,
      patterns: variants.map((v, i) => convertPattern(v, `${path}.${name}[${i}]`, stack)),
    });
  }
  stack.delete(g);
  return out;
}

mkdirSync(outDir, { recursive: true });
for (const lang of langs) {
  const g = Prism.languages[lang];
  if (!g || typeof g !== 'object') {
    console.error(`SKIP ${lang}: not a grammar object`);
    process.exitCode = 1;
    continue;
  }
  warnings = [];
  const converted = convertGrammar(g, lang, new Set(), true);
  const doc = { language: lang, prismVersion, ...converted };
  const file = join(outDir, `${lang}.json`);
  writeFileSync(file, JSON.stringify(doc, null, 1) + '\n');
  const ruleCount = converted.rules.length;
  console.log(`OK ${lang}: ${ruleCount} rules -> ${file}`);
  for (const w of warnings) console.log(`  WARN ${w}`);
}
