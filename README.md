# effen

*eff-en*, as in **F N**: function new.

Write a call to a function that doesn't exist yet, put the cursor on its name, and
let effen generate the prototype, the declaration and a definition stub.
Declarations stay in sync when you change the definition.

C and C++ are supported (also objc/objcpp/cuda via the C/C++ backends); the
language layer is pluggable.

```c
int main(void) {
  int count = 3;
  char buf[64];
  double ratio = compute(count, buf, 2.5f);   // cursor on `compute`, <leader>fn
}
```

→ prompts with `double compute(int count, char *buf, float arg3)`, then creates

```c
double compute(int count, char *buf, float arg3)
{
    |
}
```

## Requirements

- Neovim ≥ 0.11
- An LSP with hover (clangd) for argument types. Without it, types become `TYPE`
  placeholders you fill in in the prompt.

## Install (lazy.nvim)

```lua
{
  dir = "~/repos/func-factory",
  name = "effen",
  main = "effen",
  ft = { "c", "cpp", "objc", "objcpp", "cuda" },
  opts = {},
}
```

## Keys

| Keys | Action |
| --- | --- |
| `<leader>fn` | **new**: opens an option picker (below) |
| `<leader>fe` | **existing**: go to the definition of the function under the cursor (LSP goto definition), leaving the return marker |
| `<leader>fr` | **return** to the marker set by *new* / *existing*, then delete the marker |
| `<leader>fu` | **update** the declaration of the definition under the cursor (does nothing outside a definition) |

After `<leader>fn`, a small float shows toggles. Toggle keys don't run anything;
an action key does:

| Key | Toggle / action |
| --- | --- |
| `m` | modifiers: the prototype prompt opens with the cursor at the start so you can type `static`, `inline`, … |
| `\|` / `_` / `f` | open the definition in a vertical split / horizontal split / floating window (default: current window) |
| `h` | put the declaration in a header (prompted; defaults to the same-named header, created with include guards if missing, and `#include`d into the current file) |
| `l` | later: don't jump (and don't set the marker) |
| `a` or `<CR>` | **append** the definition to the end of the current file |
| `n` | create a **new** source file for the definition (prompted; defaults to `<function>.<ext>` next to the current file; appended to if it exists) |
| `<Esc>` / `q` | cancel |

Without `h`, a forward declaration is inserted below the `#include` block of the
current file, so C doesn't complain about an implicit declaration.

Before jumping, a global mark (`F` by default) is placed on the call so
`<leader>fr` brings you back.

### Existing functions

`<leader>fe` is the same round trip for a function that already exists. It asks
the LSP for the definition, then shows a one-line view picker. Each key acts
immediately because there is nothing to toggle:

| Key | View |
| --- | --- |
| `e` or `<CR>` | current window |
| `\|` / `_` / `f` | vertical split / horizontal split / floating window |
| `<Esc>` / `q` | cancel |

The marker is placed, so `<leader>fr` returns (closing the float if you used
`f`). If the LSP returns several definitions you get a `vim.ui.select` list.
If the LSP finds no definition, it says so; use `<leader>fn` to create one.

### Prompts

All prompts are rename-style floats. `<CR>` confirms, `<Esc>` (normal mode),
`q` or `<C-c>` cancels.

The prototype prompt always appears so you can check the deduced signature.
Types that couldn't be deduced are `TYPE`; the first one is already selected
(select mode, so typing replaces it) and `<Tab>` jumps to the next one. Renaming
the function in the prompt renames the call too.

## How types are deduced

**Parameters**: literals (`42`, `42UL`, `1.5f`, `"str"`, `'c'`, `NULL`, `true`),
`sizeof`, casts, `&x`, `*p`, `a[i]`, `a.b`, `p->b`, calls (return type of the
callee), macros, comparisons/logical ops (`int` in C, `bool` in C++), and
arithmetic (type of the left operand). Identifiers are resolved via LSP hover.
Arrays decay to pointers; top-level `const`/references are dropped.
Parameter names come from the argument (`count`, `p->name` → `name`), otherwise
`argN`.

**Return type**:

| Call site | Return type |
| --- | --- |
| `foo(x);` | `void` |
| `T v = foo(x);` | `T` (storage specifiers and top-level `const` dropped; `auto` → `TYPE`) |
| `v = foo(x);`, `*p = …`, `s.f += …` | hover type of the target |
| `return foo(x);` | return type of the enclosing function |
| `if (foo(x))`, `!foo(x)`, `a && foo(x)` | `int` (C) / `bool` (C++) |
| anything else | `TYPE` |

clangd can only resolve identifiers inside a statement it can parse. If the
assignment target itself is undeclared (`result = foo(x);` with no `result`),
clangd drops the whole statement and you'll get placeholders. Declare it
(`int result = foo(x);`) instead.

## Keeping declarations in sync

On load and after each save, effen snapshots the signature of every
definition. On save (`auto_update = true`), any definition whose signature
changed has its declaration rewritten: the declaration that matched the *old*
signature is found in the same file, in the file's `#include "…"` headers, in
same-named headers, or in the file a forward declaration was put in by *new*.
Matching on the old signature means renames and C++ overloads work. Default
arguments, `extern` and namespace qualification on the declaration are kept.

Other files that get updated are written if they had no unsaved changes;
otherwise they are left modified and you get a warning.

`<leader>fu` does the same for the definition under the cursor on demand.

## Commands

- `:EffenNew [keys]`: like `<leader>fn`; with keys (e.g. `:EffenNew h|a`) the picker is skipped
- `:EffenExisting [here|vsplit|split|float]`: like `<leader>fe`; with an argument the picker is skipped
- `:EffenReturn`
- `:EffenUpdate`
- `:checkhealth effen`

## Configuration

```lua
require("effen").setup({
  prefix = "<leader>f",                        -- false: no keymaps
  keys = { new = "n", existing = "e", ret = "r", update = "u" }, -- false disables one
  marker = "F",                                -- global mark used by new/existing/return
  auto_update = true,                          -- sync declarations on save
  unknown_type = "TYPE",                       -- placeholder for undeduced types
  lsp_timeout = 1000,                          -- ms per hover request
  brace_newline = true,                        -- `{` on its own line
  header_guard = "ifndef",                     -- or "pragma"
  header_ext = { c = "h", cpp = "hpp" },       -- when no header exists yet
  border = "rounded",
  float = { width = 0.8, height = 0.7 },       -- `f` view size
  languages = {},                              -- { filetype = backend }
})
```

Lua API: `require("effen").new(opts)`, `.existing({ view = "vsplit" })`, `.ret()`, `.update()`.
`new` accepts `{ keys = "h|a", prototype = "...", confirm = false, header = path, source = path }`
to skip any of the prompts.

## Adding a language

A backend is a table implementing the interface documented at the top of
`lua/effen/lang/c_family.lua` (parse the call, deduce a signature, format
prototypes, find definitions/declarations, insert into files). Register it with
`languages = { rust = require("my.backend") }` or
`require("effen.lang").register(ft, backend)`.

## Limitations (v1)

- Free functions only: calls like `obj.method()` / `p->method()` are rejected
  (no member function generation yet).
- Source scanning is heuristic (comments/strings/brackets aware, no full
  parser). Unusual macro-heavy code can confuse it.
- If the function is already declared somewhere, *new* refuses rather than
  generating a definition from the existing declaration.

## Tests

```sh
make test   # nvim --headless -u NONE -l tests/run.lua
```

The clangd integration tests use `$CLANGD`, `clangd` on `PATH`, or Mason's
clangd, and are skipped when none is found.
