# kotoshu-lsp

Language Server Protocol server wrapping the [Kotoshu](https://github.com/kotoshu/kotoshu) spell checker.

## Status

MVP. Implements `initialize`, `textDocument/didOpen|didChange|didClose`,
`textDocument/publishDiagnostics`, `textDocument/codeAction`,
`textDocument/hover`. Wraps `Kotoshu.check` directly.

Lives in the `kotoshu/` workspace as a sibling of the `kotoshu` library
gem. See `TODO.impl/60-lsp-server.md` for the full plan.

## Install

```bash
gem install kotoshu-lsp
# or from source:
cd kotoshu-lsp && bundle install && bundle exec rake install
```

Requires the `kotoshu` gem (auto-installed as a runtime dep).

## Editor wiring

### Neovim (built-in LSP)

```lua
require('lspconfig').kotoshu.setup({
  cmd = { 'kotoshu-lsp' },
  filetypes = { 'text', 'markdown', 'asciidoc' },
})
```

If `lspconfig` does not yet have a `kotoshu` entry, wire it manually:

```lua
vim.lsp.start({
  name = 'kotoshu',
  cmd = { 'kotoshu-lsp' },
  root_dir = vim.fs.dirname(vim.fs.find({ '.git' }, { upward = true })[1]),
})
```

### VS Code

Install the `kotoshu-lsp` extension (when published — `61-editor-ecosystem.md`).
Or wire it manually via `languageServerExample` extension boilerplate
with ` LanguageId: ['plaintext', 'markdown']` and
`command: 'kotoshu-lsp'`.

### Emacs (`lsp-mode`)

```elisp
(with-eval-after-load 'lsp-mode
  (add-to-list 'lsp-language-id-configuration
               '(text-mode . "plaintext"))
  (lsp-register-client
   (make-lsp-client :new-connection (lsp-stdio-connection '("kotoshu-lsp"))
                    :activation-fn (lsp-activate-on "plaintext" "markdown")
                    :server-id 'kotoshu)))
```

### Emacs (`eglot`)

```elisp
(add-to-list 'eglot-server-programs
             '((text-mode markdown-mode) . ("kotoshu-lsp")))
```

## Configuration

| Env var | Default | Purpose |
|---|---|---|
| `KOTOSHU_LSP_LOG` | unset | Path to write a per-session log |
| `KOTOSHU_LSP_LOG_LEVEL` | `info` | `debug` / `info` / `warn` / `error` |
| `KOTOSHU_OFFLINE` | unset | Never trigger downloads; misspelled words still flagged against cached dictionaries |

## Protocol surface

| Method | Status |
|---|---|
| `initialize` | ✅ |
| `initialized` / `shutdown` / `exit` | ✅ |
| `textDocument/didOpen` | ✅ publishes diagnostics |
| `textDocument/didChange` (full sync) | ✅ republishes |
| `textDocument/didClose` | ✅ clears diagnostics |
| `textDocument/publishDiagnostics` | ✅ one diag per misspelled word, top-N suggestions in `data.suggestions` |
| `textDocument/codeAction` | ✅ one quickfix per suggestion + add-to-personal-dictionary |
| `textDocument/hover` | ✅ shows top-N suggestions on a flagged word |
| `textDocument/completion` | not implemented (returns `nil`) |

## License

BSD-2-Clause, same as Kotoshu.
