# effen

*eff-en*, as in **F N**: function new.

Write a call to a function that doesn't exist yet, put the cursor on its name, and
let effen generate the prototype, the declaration and a definition stub. Or put
the cursor on a declaration that has no definition yet and get the stub. Or
select some code and let effen wrap it into a new function, replacing copies of
it in the file or the whole project. Declarations stay in sync when you change
the definition.

C and C++ are supported (also objc/objcpp/cuda via the C/C++ backends); the
language layer is pluggable.

```c
int main(void) {
  int count = 3;
  char buf[64];
  double ratio = compute(count, buf, 2.5f);   // cursor on `compute`, <leader>fnn
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

All keys live under `<leader>fn`:

| Keys | Command | Action |
| --- | --- | --- |
| `<leader>fnn` | `:EffenNew` | **new**: create the function called (or declared) under the cursor; opens an option picker (below) |
| `<leader>fne` | `:EffenEnter` | **enter** the definition of the function under the cursor (LSP goto definition), leaving the return marker |
| `<leader>fnr` | `:EffenReturn` | **return** to the marker set by *new* / *enter* / *wrap*, then delete the marker |
| `<leader>fnu` | `:EffenUpdate` | **update** the declaration of the definition under the cursor (does nothing outside a definition) |
| `<leader>fnw` (visual) | `:'<,'>EffenWrap` | **wrap** the selected code into a new function (below) |

After `<leader>fnn`, a small float shows toggles. Toggle keys don't run anything;
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
`<leader>fnr` brings you back.

### From a declaration

When the cursor is anywhere on a top-level function declaration
(`int area(int w, int);`), `<leader>fnn` creates its **definition** instead.
Calls inside function bodies always use the call flow above, so effen can tell
the two apart.

- The prompt shows the definition's prototype: unnamed parameters get names
  (`int arg2`), default arguments and `extern` are dropped. If you change the
  types or the name, the declaration is updated to match.
- `a`/`<CR>` in a **source** file appends the definition to it. In a **header**
  it appends to the same-named source file (`area.h` → `area.c`), and asks for a
  path if there isn't one. That file gets the `#include`.
- `n` puts the definition in a new source file (prompted).
- `h` on a forward declaration in a source file **moves** it to the header
  (prompted) and `#include`s the header. In a header, `h` is ignored.
- `m`, `|`/`_`/`f` and `l` work as for calls. The marker goes on the declaration.
- If the function already has a definition (same file, the header's source
  file, or the LSP's goto-definition), effen says where and does nothing.

When effen has to guess a source file extension for a header (`.h` files have
the `cpp` filetype by default), it uses the one most common among the files
next to the header.

### Entering existing functions

`<leader>fne` is the same round trip for a function that already exists. It asks
the LSP for the definition, then shows a one-line view picker. Each key acts
immediately because there is nothing to toggle:

| Key | View |
| --- | --- |
| `e` or `<CR>` | current window |
| `\|` / `_` / `f` | vertical split / horizontal split / floating window |
| `<Esc>` / `q` | cancel |

The marker is placed, so `<leader>fnr` returns (closing the float if you used
`f`). If the LSP returns several definitions you get a `vim.ui.select` list.
If the LSP finds no definition, it says so; use `<leader>fnn` to create one.

### Wrapping code into a function

Select code inside a function body (`v` for an expression or statements, `V`
for whole lines) and press `<leader>fnw`:

1. The same option picker as *new* (`m`, `h`, `|`/`_`/`f`, `l`, then `a`/`<CR>`
   or `n`) decides where the declaration and the definition go.
2. A prototype prompt opens with the deduced signature. The name
   (`extracted`) is selected, so you just type the new name; `<Tab>` then jumps
   to any `TYPE` placeholders. Edit the return type and parameters freely:
   renamed parameters are renamed in the body too.
3. The selection is replaced by the call, the definition is created with the
   selected code as its body, and the declaration is added.
4. A last picker asks what to do with **copies** of the code: `f` replaces them
   in this file, `p` in every C/C++ file of the project (git files, or the
   files under the nearest `Makefile`/`CMakeLists.txt`/`compile_commands.json`
   directory), `n`/`<Esc>` leaves them. Replaced copies go to the quickfix list
   (`:copen` to review).

What effen works out from the selection:

| Selection | Becomes |
| --- | --- |
| an expression: `a * b + 1` | `int mad(int a, int b) { return a * b + 1; }`, call `mad(a, b)` |
| statements | a `void` function, call `name(args);` |
| statements declaring a variable used after them | that variable is returned: `int sq = name(args);` |
| statements ending in `return x;` | returns the enclosing function's type: `return name(args);` |

Parameters are the local variables and parameters of the enclosing function
that the selection uses (globals, functions and macros are left alone). With an
LSP this uses goto-definition; without one, declarations are found textually.
A variable the selection assigns, increments, takes the address of (or, in
C++, calls a method on) is passed as a pointer in C (`int *total`, the body uses
`(*total)` / `p->field`, the call passes `&total`) and as a reference in C++.

Copies match token for token, ignoring whitespace and comments, with variables
allowed to have different names (`b * a + 1` is a copy of `a * b + 1` and
becomes `mad(b, a)`). An expression copy must be a whole subexpression
(`2 * a * b + 1` is not replaced), statement copies must start at a statement
boundary, and a variable the copy declares must not be used after it. Copies in
other files get the `#include` of the header (with `h`) or a forward
declaration; a `static` function is not used from other files.

You are warned when the selection has an early `return`, a `break`/`continue`
for a loop outside it, or several variables that would need returning.

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

`<leader>fnu` does the same for the definition under the cursor on demand.

## Commands

- `:EffenNew [keys]`: like `<leader>fnn`; with keys (e.g. `:EffenNew h|a`) the picker is skipped
- `:EffenEnter [here|vsplit|split|float]`: like `<leader>fne`; with an argument the picker is skipped
- `:EffenReturn`: like `<leader>fnr`
- `:EffenUpdate`: like `<leader>fnu`
- `:'<,'>EffenWrap [keys]`: like `<leader>fnw`; a plain line range (`:10,14EffenWrap`) wraps whole lines
- `:checkhealth effen`

## Configuration

```lua
require("effen").setup({
  prefix = "<leader>fn",                       -- false: no keymaps
  keys = { new = "n", enter = "e", ret = "r", update = "u", wrap = "w" }, -- false disables one
  marker = "F",                                -- global mark used by new/enter/wrap/return
  auto_update = true,                          -- sync declarations on save
  unknown_type = "TYPE",                       -- placeholder for undeduced types
  wrap_name = "extracted",                     -- default name in the wrap prompt
  lsp_timeout = 1000,                          -- ms per hover request
  brace_newline = true,                        -- `{` on its own line
  header_guard = "ifndef",                     -- or "pragma"
  header_ext = { c = "h", cpp = "hpp" },       -- when no header exists yet
  border = "rounded",
  float = { width = 0.8, height = 0.7 },       -- `f` view size
  languages = {},                              -- { filetype = backend }
})
```

Lua API: `require("effen").new(opts)`, `.enter({ view = "vsplit" })`, `.ret()`, `.update()`,
`.wrap(opts)`.
`new` accepts `{ keys = "h|a", prototype = "...", confirm = false, header = path, source = path }`
to skip any of the prompts. `wrap` accepts `keys`, `prototype`, `header`, `source`,
`replace = "file"|"project"|"none"` and `region = { srow, scol, erow, ecol, linewise }`
(0-based, `ecol` exclusive; default: the last visual selection).

## Adding a language

A backend is a table implementing the interface documented at the top of
`lua/effen/lang/c_family.lua` (parse the call, deduce a signature, format
prototypes, find definitions/declarations, insert into files). Register it with
`languages = { rust = require("my.backend") }` or
`require("effen.lang").register(ft, backend)`. The `wrap_*` functions are
optional; without them `wrap` reports the filetype as unsupported.

## Limitations (v1)

- Free functions only: calls like `obj.method()` / `p->method()` are rejected
  (no member function generation yet). Wrapping code inside a C++ method that
  uses members (`x` meaning `this->x`) produces a free function that can't see
  them.
- Source scanning is heuristic (comments/strings/brackets aware, no full
  parser). Unusual macro-heavy code can confuse it.
- On a call to a function that is already declared somewhere, *new* refuses;
  put the cursor on the declaration instead to generate its definition.

## Tests

```sh
make test   # nvim --headless -u NONE -l tests/run.lua
```

The clangd integration tests use `$CLANGD`, `clangd` on `PATH`, or Mason's
clangd, and are skipped when none is found.
