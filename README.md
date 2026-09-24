# Semantic Search for Nextpad++ (macOS)

Describe what you're looking for in plain language — every sentence in the
document is tinted **red → grey → green** by semantic similarity to your
query. Entirely on-device: Apple NaturalLanguage embeddings scored on the GPU
via Metal Performance Shaders. Nothing leaves your Mac.

**Credit:** based on [nextpad-plus-plus-macos PR #346](https://github.com/nextpad-plus-plus/nextpad-plus-plus-macos/pull/346)
by **Kristian Rickert** ([@krickert](https://github.com/krickert)) — the
embedding pipeline, Metal scoring engine, spillable vector index, color ramp
and tests are his work, adapted from an in-host feature to this standalone
plugin.

## Usage

- **Plugins → Semantic Search → Semantic Heatmap Search** opens a docked
  panel (bottom of the window on Nextpad++ 1.1.1+; it can be moved with the
  panel's dock buttons and reopens where you left it).
- Type a query — the heatmap updates live (debounced). Enter forces an
  immediate run; clearing the field clears the heatmap.
- **Strict / Standard / Broad** shifts how much similarity is needed to show
  green. Colors are relative to the model and sensitivity — they are not
  confidence percentages.
- The status line reports the index state ("214 of 230 sentences indexed ·
  Metal/MPS") and any errors. Sentences that cannot be embedded stay
  uncolored.

## Requirements & limits

- Nextpad++ for macOS 1.0.3+ (1.1.1+ recommended: bottom-dock default and
  panel restore); **macOS 14+ at runtime** for the embedding models — on
  older systems the menu item explains and does nothing else.
- A Metal/MPS-capable GPU (no CPU fallback — the plugin reports "Metal GPU
  unavailable" rather than silently degrading).
- An Apple NaturalLanguage embedding model for the document's language. The
  contextual model may be downloaded on demand **by macOS** (an OS-managed
  asset, like a dictation language); the static sentence model is used until
  it arrives.
- Documents over 2 MiB or 4,096 sentences are refused rather than partially
  searched. Non-UTF-8 documents are refused.

## Building

```sh
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j
ctest --test-dir build --output-on-failure   # unit tests (colors + index)
cmake --install build                        # → ~/Library/…/Nextpad++/plugins/SemanticSearch
```

Requires the `nextpad-plus-plus-macos` repo checked out as a sibling
directory (plugin interface + Scintilla headers).

## License

GPL-3.0, matching the host and the original contribution.
