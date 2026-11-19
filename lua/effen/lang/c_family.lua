-- Shared backend for C-like languages (C, C++). A concrete language is made
-- with `require("effen.lang.c_family").new(spec)`.
--
-- Backend interface used by the rest of the plugin (implement the same
-- functions to add another language):
--   parse_call(buf, row, col)            -> call | nil, err
--   deduce_signature(buf, call, hover)   -> sig
--   format_prototype(sig)                -> string
--   parse_proto(text)                    -> proto | nil
--   definition_lines(proto_text, indent) -> lines, body_offset
--   declaration_text(proto_text)         -> string
--   declaration_from_definition(def, old_decl) -> string
--   definitions(lines) / declarations(lines)    -> items with positions
--   same_types(a, b)                     -> bool
--   header_candidates(path) / default_header(path) / default_source(path, name)
--   new_header_lines(path)
--   insert_declaration(buf, text)        (into a header)
--   insert_forward_declaration(buf, text)
--   ensure_include(buf, header_path)
--   includes(lines, dir)                 -> absolute paths of local includes
--   extensions()                         -> file extensions of the language
--   is_header(path) / source_candidates(header_path)
--   declaration_at(buf, row, col)        -> declaration under the cursor | nil
--   definition_proto(decl_proto)         -> prototype text for its definition
--   wrap_analyze / wrap_build / wrap_find      (see lang/c_wrap.lua)
local lex = require("effen.lang.c_lex")
local util = require("effen.util")

local F = {}

local SKIP_CALL = {
  __attribute__ = true,
  __declspec = true,
  alignas = true,
  _Alignas = true,
  decltype = true,
  typeof = true,
  __typeof__ = true,
  __typeof = true,
  sizeof = true,
  noexcept = true,
  throw = true,
  ["if"] = true,
  ["while"] = true,
  ["for"] = true,
  ["switch"] = true,
  ["return"] = true,
  __asm__ = true,
  asm = true,
}

local TYPE_WORDS = {
  int = true,
  char = true,
  short = true,
  long = true,
  unsigned = true,
  signed = true,
  float = true,
  double = true,
  void = true,
  bool = true,
  _Bool = true,
  const = true,
  volatile = true,
  auto = true,
  wchar_t = true,
  char8_t = true,
  char16_t = true,
  char32_t = true,
  restrict = true,
  __restrict = true,
}

local STORAGE = {
  static = true,
  extern = true,
  inline = true,
  register = true,
  thread_local = true,
  _Thread_local = true,
  constexpr = true,
  consteval = true,
  constinit = true,
  virtual = true,
  explicit = true,
  mutable = true,
  __inline = true,
  __inline__ = true,
}

local CONTROL = { ["if"] = true, ["while"] = true, ["for"] = true, ["switch"] = true }
F.TYPE_WORDS, F.STORAGE = TYPE_WORDS, STORAGE

local KEYWORDS = {
  ["return"] = true,
  ["else"] = true,
  ["case"] = true,
  ["do"] = true,
  ["goto"] = true,
  ["sizeof"] = true,
  ["new"] = true,
  ["delete"] = true,
  ["throw"] = true,
  ["co_return"] = true,
}

--------------------------------------------------------------------------------
-- Type string helpers
--------------------------------------------------------------------------------

--- Canonical form for comparing types: single spaces, none around punctuation.
function F.normalize_type(t)
  t = vim.trim((t or ""):gsub("%s+", " "))
  t = t:gsub("%s*([%*&%[%]%(%),<>:])%s*", "%1")
  return t
end

--- Pretty form: single spaces, `char *` style pointers.
function F.pretty_type(t)
  t = vim.trim((t or ""):gsub("%s+", " "))
  t = t:gsub("%s*%*", " *"):gsub("%*%s+%*", "**"):gsub("%*%s+%*", "**")
  t = t:gsub("%s*&", " &"):gsub("&%s+&", "&&")
  return vim.trim(t)
end

function F.add_ptr(t)
  if not t then
    return nil
  end
  t = F.pretty_type(t)
  if t:match("%*$") then
    return t .. "*"
  end
  return t .. " *"
end

function F.strip_ptr(t)
  if not t then
    return nil
  end
  t = F.pretty_type(t)
  local base = t:match("^(.-)%s*%*%s*const$") or t:match("^(.-)%s*%*$")
  if base then
    return vim.trim(base)
  end
  base = t:match("^(.-)%s*%[[^%]]*%]$")
  if base then
    return vim.trim(base)
  end
  return nil
end

--- Cleans a type reported by the LSP for use as a by-value parameter type.
function F.clean_type(t)
  if not t then
    return nil
  end
  t = vim.trim(t)
  local base = t:match("^(.-)%s*%[[^%]]*%]$")
  if base then
    return F.add_ptr(base) -- arrays decay to pointers
  end
  t = t:gsub("%s*&&?$", "")
  if not t:find("[%*&]") then
    t = t:gsub("^const%s+", ""):gsub("%s+const$", "")
  end
  return F.pretty_type(t)
end

local function join_type_name(t, name)
  if t:match("[%*&]$") then
    return t .. name
  end
  return t .. " " .. name
end
F.join_type_name = join_type_name

local function strip_storage(prefix)
  local words = {}
  for w in prefix:gmatch("%S+") do
    words[#words + 1] = w
  end
  local i = 1
  while words[i] and STORAGE[words[i]] do
    i = i + 1
  end
  local t = table.concat(words, " ", i)
  if t == "" or t:match("^auto") or t:match("decltype%s*%(%s*auto") then
    return nil
  end
  if not t:find("[%*&]") then
    t = t:gsub("^const%s+", "")
  end
  return F.pretty_type(t)
end
F.strip_storage = strip_storage

--------------------------------------------------------------------------------
-- Prototype parsing
--------------------------------------------------------------------------------

local function parse_param(p)
  p = vim.trim(p)
  local default
  local eq = lex.find_top_assign(p, true)
  if eq then
    default = vim.trim(p:sub(eq + 1))
    p = vim.trim(p:sub(1, eq - 1))
  end
  local param = { text = p, default = default }
  if p == "..." or p == "void" then
    param.type = p
    return param
  end
  -- function pointer: ret (*name)(args)
  local pre, fname, post = p:match("^(.-%(%s*[%*&^]%s*)([%a_][%w_]*)(%s*%).*)$")
  if fname then
    param.type, param.name = vim.trim(pre .. post), fname
    return param
  end
  local base, arr = p:match("^(.-)%s*(%[.*%])$")
  if not base then
    base, arr = p, ""
  end
  local ty, nm = base:match("^(.-[%s%*&>])([%a_][%w_]*)$")
  if ty and not TYPE_WORDS[nm] then
    local core = vim.trim(ty)
    local bare = core:gsub("%f[%w_]const%f[^%w_]", ""):gsub("%f[%w_]volatile%f[^%w_]", "")
    local tag_only = core:match("^struct$") or core:match("^union$") or core:match("^enum$") or core:match("^class$")
    if not util.is_blank(bare) and not tag_only and not core:match("::$") then
      param.type, param.name = core .. arr, nm
      return param
    end
  end
  param.type = p
  return param
end

--- Parses a function prototype (declaration or definition header, without
--- the trailing `;` / `{`).
---@return table|nil { prefix, name, base, params = {...}, params_text, suffix }
function F.parse_proto(text)
  text = vim.trim(lex.strip_comments(text or ""))
  local n = #text
  local i = 1
  local angle = 0
  while i <= n do
    local c = text:sub(i, i)
    local kind, j = lex.skip_special(text, i)
    if kind then
      i = j
    elseif c == "<" then
      angle = angle + 1
      i = i + 1
    elseif c == ">" and angle > 0 then
      angle = angle - 1
      i = i + 1
    elseif c == "(" then
      local close = lex.matching(text, i)
      if not close then
        return nil
      end
      local before = text:sub(1, i - 1)
      local name = before:match("([%a_:~][%w_:~]*)%s*$")
      local base = name and name:match("([~%a_][%w_]*)$")
      if angle == 0 and base and not SKIP_CALL[base] and not TYPE_WORDS[base] then
        local prefix = vim.trim(before:sub(1, #before - #before:match("[%w_:~]*%s*$")))
        local no_tmpl = prefix:gsub("%b<>", "")
        if
          prefix == ""
          or no_tmpl:find("=", 1, true)
          or prefix:match("^typedef%f[^%w_]")
          or prefix:match("^using%f[^%w_]")
          or prefix:match("[%.%-]$")
          or KEYWORDS[prefix]
        then
          return nil
        end
        local params_text = text:sub(i + 1, close - 1)
        local params = {}
        local trimmed = vim.trim(params_text)
        if trimmed ~= "" and trimmed ~= "void" then
          for _, r in ipairs(lex.split_top(params_text, ",", true)) do
            params[#params + 1] = parse_param(params_text:sub(r[1], r[2]))
          end
        end
        return {
          prefix = prefix:gsub("%s+", " "),
          name = name,
          base = base,
          params = params,
          params_text = trimmed,
          suffix = vim.trim(text:sub(close + 1):gsub("%s+", " ")),
        }
      end
      i = close + 1
    else
      i = i + 1
    end
  end
  return nil
end

--- Normalized parameter type list.
function F.param_types(proto)
  local out = {}
  for _, p in ipairs(proto.params) do
    out[#out + 1] = F.normalize_type(p.type)
  end
  return out
end

function F.same_types(a, b)
  local ta, tb = F.param_types(a), F.param_types(b)
  if #ta ~= #tb then
    return false
  end
  for i = 1, #ta do
    if ta[i] ~= tb[i] then
      return false
    end
  end
  return true
end

--- Single-line rendering of a parsed prototype.
---@param opts? { defaults: boolean, name: string, prefix: string }
function F.render_proto(p, opts)
  opts = opts or {}
  local params = {}
  for _, prm in ipairs(p.params) do
    local t = prm.text:gsub("%s+", " ")
    if opts.defaults ~= false and prm.default then
      t = t .. " = " .. prm.default
    end
    params[#params + 1] = t
  end
  local ptext = #params > 0 and table.concat(params, ", ") or p.params_text
  local head = join_type_name(opts.prefix or p.prefix, opts.name or p.name)
  local s = head .. "(" .. ptext .. ")"
  if p.suffix ~= "" then
    s = s .. " " .. p.suffix
  end
  return s
end

--------------------------------------------------------------------------------
-- Top-level scanner
--------------------------------------------------------------------------------

local function is_transparent(header)
  header = vim.trim(header)
  return header:match("^namespace%f[^%w_]") ~= nil
    or header:match("^inline%s+namespace%f[^%w_]") ~= nil
    or header:match('^extern%s*"C%+*"$') ~= nil
end

--- Scans source lines for top-level items. Namespaces and `extern "C"` blocks
--- are transparent. Returns a list of
---   { kind = "block"|"stmt", text, s, e, body_end }
--- where s/e/body_end are 1-based indices into `T.str` (`e` is the `{` or `;`).
function F.scan(lines)
  local T = util.text(lines)
  local s = T.str
  local n = #s
  local items = {}
  local i = 1
  local stack = 0
  local depth = 0
  local opaque
  local stmt_start
  local line_start = true

  local function reset()
    stmt_start = nil
  end

  while i <= n do
    local c = s:sub(i, i)
    if c == "\n" then
      line_start = true
      i = i + 1
    elseif c:match("%s") then
      i = i + 1
    elseif c == "#" and line_start then
      local j = i
      while true do
        local e = s:find("\n", j, true)
        if not e then
          j = n + 1
          break
        end
        if s:sub(e - 1, e - 1) == "\\" then
          j = e + 1
        else
          j = e
          break
        end
      end
      if depth == 0 then
        reset()
      end
      i = j
    else
      line_start = false
      local kind, j = lex.skip_special(s, i)
      if kind then
        if kind == "string" and depth == 0 and not stmt_start then
          stmt_start = i
        end
        i = j
      elseif depth > 0 then
        if c == "{" then
          depth = depth + 1
        elseif c == "}" then
          depth = depth - 1
          if depth == 0 then
            opaque.body_end = i
            items[#items + 1] = opaque
            opaque = nil
            reset()
          end
        end
        i = i + 1
      elseif c == "{" then
        local header = stmt_start and lex.strip_comments(s:sub(stmt_start, i - 1)) or ""
        if is_transparent(header) then
          stack = stack + 1
          reset()
        else
          opaque = { kind = "block", s = stmt_start or i, e = i, text = header }
          depth = 1
        end
        i = i + 1
      elseif c == "}" then
        if stack > 0 then
          stack = stack - 1
        end
        reset()
        i = i + 1
      elseif c == ";" then
        if stmt_start then
          items[#items + 1] = {
            kind = "stmt",
            s = stmt_start,
            e = i,
            text = lex.strip_comments(s:sub(stmt_start, i - 1)),
          }
        end
        reset()
        i = i + 1
      elseif c == "(" or c == "[" then
        if not stmt_start then
          stmt_start = i
        end
        local close = lex.matching(s, i)
        i = (close or n) + 1
      else
        if not stmt_start then
          stmt_start = i
        end
        i = i + 1
      end
    end
  end
  if opaque then -- unterminated body (still being typed)
    opaque.body_end = n
    items[#items + 1] = opaque
  end
  return items, T
end

local function with_positions(item, T, proto)
  local srow, scol = T.pos(item.s)
  local erow, ecol = T.pos(item.e)
  local out = {
    kind = item.kind,
    text = item.text,
    proto = proto,
    srow = srow,
    scol = scol,
    erow = erow,
    ecol = ecol,
  }
  if item.body_end then
    out.body_end_row = T.pos(item.body_end)
  end
  return out
end

--- Function definitions in `lines`.
function F.definitions(lines)
  local items, T = F.scan(lines)
  local out = {}
  for _, it in ipairs(items) do
    if it.kind == "block" then
      local p = F.parse_proto(it.text)
      if p then
        out[#out + 1] = with_positions(it, T, p)
      end
    end
  end
  return out
end

--- Function declarations (prototypes) in `lines`.
function F.declarations(lines)
  local items, T = F.scan(lines)
  local out = {}
  for _, it in ipairs(items) do
    if it.kind == "stmt" then
      local p = F.parse_proto(it.text)
      if p then
        out[#out + 1] = with_positions(it, T, p)
      end
    end
  end
  return out
end

--------------------------------------------------------------------------------
-- Declarations / definitions text
--------------------------------------------------------------------------------

function F.declaration_text(proto_text)
  return vim.trim(proto_text):gsub(";%s*$", "") .. ";"
end

--- Builds a new declaration from definition `def` (a parsed proto), keeping
--- declaration-only bits (default arguments, `extern`, qualification) from
--- `old` when given.
function F.declaration_from_definition(def, old)
  local params = vim.deepcopy(def.params)
  local opts = {}
  if old then
    for idx, prm in ipairs(params) do
      local o = old.params[idx]
      if o and o.default and not prm.default then
        prm.default = o.default
      end
    end
    local qual = old.name:match("^(.*::)") or ""
    opts.name = qual .. def.base
    if old.prefix:match("^extern%f[^%w_]") and not def.prefix:match("^extern%f[^%w_]") then
      opts.prefix = "extern " .. def.prefix
    end
  end
  local p = vim.tbl_extend("force", def, { params = params })
  return F.render_proto(p, opts) .. ";"
end

--------------------------------------------------------------------------------
-- Language object
--------------------------------------------------------------------------------

---@param spec table { name, filetypes, header_exts, source_exts, default_header_ext,
---  bool_type, empty_params, null_type, references }
--- `references`: out-parameters of wrapped code become `T &` (else `T *`).
function F.new(spec)
  local L = setmetatable({ name = spec.name }, { __index = F })
  local config = function()
    return require("effen.config").get()
  end

  local function unknown()
    return config().unknown_type
  end

  ------------------------------------------------------------------------------
  -- Files
  ------------------------------------------------------------------------------

  function L.header_candidates(path)
    local root = vim.fn.fnamemodify(path, ":r")
    local out = {}
    for _, ext in ipairs(spec.header_exts) do
      out[#out + 1] = root .. "." .. ext
    end
    return out
  end

  function L.default_header(path)
    for _, h in ipairs(L.header_candidates(path)) do
      if vim.fn.filereadable(h) == 1 or util.loaded_buf(h) then
        return h
      end
    end
    local ext = (config().header_ext or {})[spec.name] or spec.default_header_ext
    return vim.fn.fnamemodify(path, ":r") .. "." .. ext
  end

  --- Source extensions to try for files next to `path`, most used in its
  --- directory first (`.h` files are `cpp` by default even in C projects).
  local function source_exts_near(path)
    local exts = vim.list_extend(vim.list_extend({}, spec.source_exts), { "c", "cpp", "cc", "cxx" })
    local count, order, seen = {}, {}, {}
    for _, e in ipairs(exts) do
      if not seen[e] then
        seen[e] = true
        order[#order + 1] = e
        count[e] = 0
      end
    end
    local dir = vim.fs.dirname(util.abspath(path))
    if vim.fn.isdirectory(dir) == 1 then
      for name, kind in vim.fs.dir(dir) do
        local e = name:match("%.([^.]+)$")
        if kind == "file" and e and count[e] then
          count[e] = count[e] + 1
        end
      end
    end
    local rank = {}
    for i, e in ipairs(order) do
      rank[e] = i
    end
    table.sort(order, function(a, b)
      if count[a] ~= count[b] then
        return count[a] > count[b]
      end
      return rank[a] < rank[b]
    end)
    return order
  end

  function L.default_source(path, fname)
    local ext = vim.fn.fnamemodify(path, ":e")
    if ext == "" or vim.tbl_contains(spec.header_exts, ext) then
      ext = source_exts_near(path)[1]
    end
    return vim.fs.joinpath(vim.fs.dirname(path), fname .. "." .. ext)
  end

  function L.is_header(path)
    return vim.tbl_contains(spec.header_exts, vim.fn.fnamemodify(path, ":e"))
  end

  --- Possible same-named source files of a header (this language first).
  function L.source_candidates(path)
    local root = vim.fn.fnamemodify(path, ":r")
    local out = {}
    for _, ext in ipairs(source_exts_near(path)) do
      out[#out + 1] = root .. "." .. ext
    end
    return out
  end

  --- The top-level function declaration (prototype) containing (row, col),
  --- with `name_row`/`name_col` of its name.
  function L.declaration_at(buf, row, col)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for _, d in ipairs(F.declarations(lines)) do
      local after_start = row > d.srow or (row == d.srow and col >= d.scol)
      local before_end = row < d.erow or (row == d.erow and col <= d.ecol)
      if after_start and before_end then
        for r = d.srow, d.erow do
          local from = r == d.srow and d.scol + 1 or 1
          local s = lines[r + 1]:find("%f[%w_~]" .. vim.pesc(d.proto.base) .. "%s*%(", from)
          if s then
            d.name_row, d.name_col = r, s - 1
            break
          end
        end
        d.name_row = d.name_row or d.srow
        d.name_col = d.name_col or d.scol
        return d
      end
    end
  end

  --- Prototype for the definition of a declaration: unnamed parameters get
  --- names, default arguments and `extern` are dropped.
  function L.definition_proto(p)
    local q = vim.deepcopy(p)
    for i, prm in ipairs(q.params) do
      if not prm.name and prm.type ~= "void" and prm.type ~= "..." then
        local nm = "arg" .. i
        local t = prm.type
        local fp = t:find("%(%s*[%*&^]%s*%)")
        if fp then -- unnamed function pointer: void (*)(int)
          prm.text = t:gsub("%(%s*([%*&^])%s*%)", "(%1" .. nm .. ")", 1)
        else
          local base, arr = t:match("^(.-)%s*(%[.*%])$")
          prm.text = base and (join_type_name(base, nm) .. arr) or join_type_name(t, nm)
        end
        prm.name = nm
      end
    end
    return F.render_proto(q, { defaults = false, prefix = q.prefix:gsub("^extern%s+", "") })
  end

  function L.extensions()
    return vim.list_extend(vim.list_extend({}, spec.source_exts), spec.header_exts)
  end

  function L.new_header_lines(path)
    if config().header_guard == "pragma" then
      return { "#pragma once", "" }
    end
    local guard = vim.fn.fnamemodify(path, ":t"):upper():gsub("[^%w]", "_")
    if guard:match("^%d") then
      guard = "_" .. guard
    end
    return { "#ifndef " .. guard, "#define " .. guard, "", "#endif /* " .. guard .. " */" }
  end

  --- Absolute paths of `#include "..."` files that exist.
  function L.includes(lines, dir)
    local out = {}
    for _, l in ipairs(lines) do
      local inc = l:match('^%s*#%s*include%s*"([^"]+)"')
      if inc then
        local p = util.abspath(vim.fs.joinpath(dir, inc))
        if vim.fn.filereadable(p) == 1 or util.loaded_buf(p) then
          out[#out + 1] = p
        end
      end
    end
    return out
  end

  local function last_include_row(lines)
    local last
    for i, l in ipairs(lines) do
      if l:match("^%s*#%s*include") then
        last = i - 1
      end
    end
    return last
  end

  --- First row after a leading comment block (license headers etc).
  local function top_of_code(lines)
    local i = 1
    local in_block = false
    while lines[i] do
      local l = lines[i]
      if in_block then
        if l:find("*/", 1, true) then
          in_block = false
        end
      elseif l:match("^%s*/%*") then
        in_block = not l:find("*/", 1, true)
      elseif not (util.is_blank(l) or l:match("^%s*//")) then
        break
      end
      i = i + 1
    end
    return i - 1
  end

  --- Include guard info: { kind = "ifndef"|"pragma", after = 0-based row
  --- right below the guard }.
  local function guard_info(lines)
    for i = 1, math.min(#lines, 40) do
      if lines[i]:match("^%s*#%s*ifndef") and lines[i + 1] and lines[i + 1]:match("^%s*#%s*define") then
        return { kind = "ifndef", after = i + 1 }
      end
      if lines[i]:match("^%s*#%s*pragma%s+once") then
        return { kind = "pragma", after = i }
      end
    end
  end

  local function is_proto_line(l)
    return l ~= nil and l:match("^[%w_].*%)[%w_%s]*;%s*$") ~= nil and not l:match("^return%f[^%w_]")
  end

  function L.ensure_include(buf, header_path)
    local file = vim.api.nvim_buf_get_name(buf)
    local dir = vim.fs.dirname(util.abspath(file))
    local habs = util.abspath(header_path)
    if habs == util.abspath(file) then
      return
    end
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for _, l in ipairs(lines) do
      local inc = l:match('^%s*#%s*include%s*"([^"]+)"')
      if inc and (util.abspath(vim.fs.joinpath(dir, inc)) == habs or vim.fs.basename(inc) == vim.fs.basename(habs)) then
        return
      end
    end
    local rel = vim.fs.relpath(dir, habs) or vim.fs.basename(habs)
    local line = '#include "' .. rel .. '"'
    if util.is_blank(table.concat(lines)) then
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { line })
      return
    end
    local r = last_include_row(lines)
    if r then
      vim.api.nvim_buf_set_lines(buf, r + 1, r + 1, false, { line })
      return
    end
    local guard = guard_info(lines)
    local at = guard and guard.after or top_of_code(lines)
    local ins = { line }
    if lines[at + 1] and not util.is_blank(lines[at + 1]) then
      ins[#ins + 1] = ""
    end
    if at > 0 and not util.is_blank(lines[at]) then
      table.insert(ins, 1, "")
    end
    vim.api.nvim_buf_set_lines(buf, at, at, false, ins)
  end

  --- Inserts a prototype below the include block of a source file.
  function L.insert_forward_declaration(buf, decl)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local anchor = last_include_row(lines)
    if not anchor then
      local top = top_of_code(lines)
      if lines[top + 1] and is_proto_line(lines[top + 1]) then
        local j = top + 1
        while is_proto_line(lines[j + 1]) do
          j = j + 1
        end
        vim.api.nvim_buf_set_lines(buf, j, j, false, { decl })
      else
        vim.api.nvim_buf_set_lines(buf, top, top, false, { decl, "" })
      end
      return
    end
    local i = anchor + 1 -- 0-based row after the last include
    local nxt = lines[i + 1]
    if nxt == nil then
      vim.api.nvim_buf_set_lines(buf, i, i, false, { "", decl })
    elseif util.is_blank(nxt) then
      local j = i + 1
      while is_proto_line(lines[j + 1]) do
        j = j + 1
      end
      if j > i + 1 then
        vim.api.nvim_buf_set_lines(buf, j, j, false, { decl })
      else
        local ins = { decl }
        if lines[i + 2] and not util.is_blank(lines[i + 2]) then
          ins[#ins + 1] = ""
        end
        vim.api.nvim_buf_set_lines(buf, i + 1, i + 1, false, ins)
      end
    else
      vim.api.nvim_buf_set_lines(buf, i, i, false, { "", decl, "" })
    end
  end

  --- Inserts a declaration into a header, before its closing include guard
  --- (and before a trailing `extern "C"` close block).
  function L.insert_declaration(buf, decl)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local last = #lines
    while last > 0 and util.is_blank(lines[last]) do
      last = last - 1
    end
    local guard = guard_info(lines)
    local guarded = guard and guard.kind == "ifndef" and lines[last] and lines[last]:match("^%s*#%s*endif")
    if not guarded then
      local ins = { decl }
      if last > 0 and not is_proto_line(lines[last]) then
        table.insert(ins, 1, "")
      end
      vim.api.nvim_buf_set_lines(buf, last, -1, false, ins)
      return
    end
    local stop = last -- 1-based index of the closing #endif
    -- #ifdef __cplusplus / } / #endif footer
    if
      stop >= 4
      and lines[stop - 1]:match("^%s*#%s*endif")
      and lines[stop - 2]:match("^%s*}")
      and lines[stop - 3]:match("^%s*#%s*ifdef%s+__cplusplus")
    then
      stop = stop - 3
    end
    local p = stop
    while p > 1 and util.is_blank(lines[p - 1]) do
      p = p - 1
    end
    local prev = lines[p - 1]
    local ins = { decl }
    if prev and not is_proto_line(prev) then
      table.insert(ins, 1, "")
    end
    if p == stop then
      ins[#ins + 1] = ""
    end
    vim.api.nvim_buf_set_lines(buf, p - 1, p - 1, false, ins)
  end

  ------------------------------------------------------------------------------
  -- Definitions
  ------------------------------------------------------------------------------

  --- Definition template. Returns lines and the offset of the body line.
  --- `body` (already indented lines) replaces the empty body line.
  function L.definition_lines(proto_text, indent, body)
    local p = F.parse_proto(proto_text)
    local head = proto_text
    if p then
      local prefix = p.prefix:gsub("^extern%s+", "")
      head = F.render_proto(p, { defaults = false, prefix = prefix })
    end
    body = body or { indent }
    if config().brace_newline then
      return vim.list_extend({ head, "{" }, vim.list_extend(vim.list_extend({}, body), { "}" })), 2
    end
    return vim.list_extend({ head .. " {" }, vim.list_extend(vim.list_extend({}, body), { "}" })), 1
  end

  ------------------------------------------------------------------------------
  -- Call-site parsing
  ------------------------------------------------------------------------------

  --- Parses the call expression whose function name is under the cursor.
  function L.parse_call(buf, row, col)
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1] or ""
    local s, e = col + 1, col + 1
    if not line:sub(s, s):match("[%w_]") then
      -- allow the cursor on the `(` right after the name
      if line:sub(s, s) == "(" and line:sub(s - 1, s - 1):match("[%w_]") then
        s, e = s - 1, s - 1
      else
        return nil, "cursor is not on a function name"
      end
    end
    while s > 1 and line:sub(s - 1, s - 1):match("[%w_]") do
      s = s - 1
    end
    while e < #line and line:sub(e + 1, e + 1):match("[%w_]") do
      e = e + 1
    end
    local name = line:sub(s, e)
    if name:match("^%d") or KEYWORDS[name] or CONTROL[name] then
      return nil, "`" .. name .. "` is not a function name"
    end
    local before = line:sub(1, s - 1)
    if before:match("%.%s*$") or before:match("%->%s*$") then
      return nil, "member functions are not supported yet"
    end

    local last = math.min(vim.api.nvim_buf_line_count(buf), row + 200)
    local T = util.text(vim.api.nvim_buf_get_lines(buf, row, last, false), row)
    local str = T.str
    local open = str:find("%S", e + 1)
    if not open or str:sub(open, open) ~= "(" then
      return nil, "`" .. name .. "` is not followed by an argument list"
    end
    local close = lex.matching(str, open)
    if not close then
      return nil, "unbalanced parentheses after `" .. name .. "`"
    end

    local args = {}
    local inner = str:sub(open + 1, close - 1)
    if not util.is_blank(inner) then
      for _, r in ipairs(lex.split_top(inner, ",")) do
        local raw = inner:sub(r[1], r[2])
        local text, lead = util.trim_lead(raw)
        local base = open + r[1] + lead -- index in `str` of the arg's first char
        args[#args + 1] = {
          text = text,
          at = function(k)
            return T.pos(base + k - 1)
          end,
        }
      end
    end

    local after = str:sub(close + 1):match("^%s*(.)")

    -- statement context before the name (current line, maybe the previous one)
    local prefix_lines = { before }
    local prefix_row = row
    if util.is_blank(before) and row > 0 then
      local prev = vim.api.nvim_buf_get_lines(buf, row - 1, row, false)[1]
      if prev and not prev:match("[;{}]%s*$") and not prev:match("^%s*#") then
        prefix_lines = { prev, before }
        prefix_row = row - 1
      end
    end
    local PT = util.text(prefix_lines, prefix_row)

    return {
      name = name,
      row = row,
      name_col = s - 1,
      name_end = e,
      args = args,
      after = after,
      prefix = PT.str,
      prefix_at = function(k)
        return PT.pos(k)
      end,
    }
  end

  ------------------------------------------------------------------------------
  -- Type deduction
  ------------------------------------------------------------------------------

  function L.literal_type(e)
    local sp = e:match('^([LuU8]*)R?"')
    if sp then
      local ch = ({ L = "wchar_t", u = "char16_t", U = "char32_t" })[sp] or "char"
      return "const " .. ch .. " *"
    end
    local cp = e:match("^([LuU8]*)'")
    if cp then
      return ({ L = "wchar_t", u = "char16_t", U = "char32_t" })[cp] or "char"
    end
    if e == "true" or e == "false" then
      return "bool"
    end
    if e == "NULL" or e == "nullptr" then
      return spec.null_type
    end
    local num = e:gsub("'", "")
    local int_suffix = num:match("^0[xX]%x+([uUlLzZ]*)$")
      or num:match("^0[bB][01]+([uUlLzZ]*)$")
      or num:match("^%d+([uUlLzZ]*)$")
    if int_suffix then
      local suf = int_suffix:lower()
      local unsigned = suf:find("u") ~= nil
      local longs = select(2, suf:gsub("l", ""))
      local base = longs == 2 and "long long" or longs == 1 and "long" or "int"
      if suf:find("z") then
        return unsigned and "size_t" or "ptrdiff_t"
      end
      return unsigned and ("unsigned " .. base) or base
    end
    if num:match("%d") then
      local fsuf = num:match("^%d*%.?%d*[eE][%+%-]?%d+([fFlL]?)$")
        or num:match("^%d*%.%d*([fFlL]?)$")
        or num:match("^0[xX][%x%.]+[pP][%+%-]?%d+([fFlL]?)$")
      if fsuf then
        fsuf = fsuf:lower()
        return fsuf == "f" and "float" or fsuf == "l" and "long double" or "double"
      end
    end
    return nil
  end

  local function shift(at, by)
    return function(k)
      return at(k + by - 1)
    end
  end

  local function hover_type(hover, at, k)
    if not hover then
      return nil
    end
    local info = hover(at(k))
    if not info then
      return nil
    end
    if info.kind == "macro" and info.expansion then
      return L.literal_type(vim.trim(info.expansion))
    end
    return info.type and F.clean_type(info.type), info
  end

  local function looks_like_type(s)
    return s:match("^[%w_%s%*&:<>,]+$") ~= nil and not s:match("^%s*%d")
  end

  --- Deduces the type of expression `e`; `at(k)` maps index k of `e` to a
  --- buffer (row, col); `hover(row, col)` returns parsed LSP hover info.
  function L.deduce_expr(e, at, hover)
    local lead
    e, lead = util.trim_lead(e)
    at = shift(at, lead + 1)
    if e == "" then
      return nil
    end
    if e:sub(1, 1) == "(" and lex.matching(e, 1) == #e then
      return L.deduce_expr(e:sub(2, -2), shift(at, 2), hover)
    end

    local ops = lex.top_ops(e)
    -- ternary
    for idx, op in ipairs(ops) do
      if op.op == "?" then
        for k = idx + 1, #ops do
          if ops[k].op == ":" then
            return L.deduce_expr(e:sub(op.i + 1, ops[k].i - 1), shift(at, op.i + 1), hover)
          end
        end
      end
    end
    for _, op in ipairs(ops) do
      if
        op.op == "||"
        or op.op == "&&"
        or op.op == "=="
        or op.op == "!="
        or op.op == "<="
        or op.op == ">="
        or (op.binary and (op.op == "<" or op.op == ">"))
      then
        return spec.bool_type
      end
    end
    local ARITH = {
      ["+"] = true,
      ["-"] = true,
      ["*"] = true,
      ["/"] = true,
      ["%"] = true,
      ["&"] = true,
      ["|"] = true,
      ["^"] = true,
      ["<<"] = true,
      [">>"] = true,
      ["="] = true,
    }
    for _, op in ipairs(ops) do
      if op.binary and ARITH[op.op] then
        return L.deduce_expr(e:sub(1, op.i - 1), at, hover)
      end
    end

    -- prefix operators
    local c, c2 = e:sub(1, 1), e:sub(2, 2)
    if (c == "+" and c2 == "+") or (c == "-" and c2 == "-") then
      return L.deduce_expr(e:sub(3), shift(at, 3), hover)
    end
    if c == "&" then
      return F.add_ptr(L.deduce_expr(e:sub(2), shift(at, 2), hover))
    end
    if c == "*" then
      return F.strip_ptr(L.deduce_expr(e:sub(2), shift(at, 2), hover))
    end
    if c == "!" then
      return spec.bool_type
    end
    if c == "-" or c == "+" or c == "~" then
      return L.deduce_expr(e:sub(2), shift(at, 2), hover)
    end
    if c == "(" then -- cast
      local close = lex.matching(e, 1)
      if close and close < #e and looks_like_type(e:sub(2, close - 1)) then
        return F.pretty_type(e:sub(2, close - 1))
      end
    end

    local lit = L.literal_type(e)
    if lit then
      return lit
    end
    if e:match("^sizeof%f[^%w_]") or e:match("^_?[Aa]lignof%f[^%w_]") then
      return "size_t"
    end
    local cast = e:match("^[%a_]*_cast%s*<(.-)>%s*%(")
    if cast then
      return F.pretty_type(cast)
    end
    if e:match("%+%+$") or e:match("%-%-$") then
      return L.deduce_expr(e:sub(1, -3), at, hover)
    end

    if e:sub(-1) == ")" then -- call: return type of the callee
      local open = lex.matching_back(e, #e)
      local callee = open and e:sub(1, open - 1) or ""
      local id = callee:find("[%a_][%w_]*%s*$")
      if id then
        local _, info = hover_type(hover, at, id)
        if info and info.ret then
          return F.clean_type(info.ret)
        end
      end
      return nil
    end
    if e:sub(-1) == "]" then
      local open = lex.matching_back(e, #e)
      return open and F.strip_ptr(L.deduce_expr(e:sub(1, open - 1), at, hover))
    end
    local id = e:find("[%a_][%w_]*$")
    if id then
      return (hover_type(hover, at, id))
    end
    return nil
  end

  --- A parameter name derived from an argument expression.
  local function arg_name(e)
    e = vim.trim(e):gsub("^[&%*]+", ""):gsub("%[.*%]$", "")
    local id = e:match("^[%a_][%w_]*$") or e:match("[%.>:]([%a_][%w_]*)$")
    if
      id
      and not TYPE_WORDS[id]
      and not KEYWORDS[id]
      and id ~= "NULL"
      and id ~= "nullptr"
      and id ~= "true"
      and id ~= "false"
    then
      return id
    end
  end

  local function return_type_of_enclosing(buf, row)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    for _, d in ipairs(F.definitions(lines)) do
      if d.srow <= row and (d.body_end_row or d.erow) >= row then
        return strip_storage(d.proto.prefix)
      end
    end
  end

  --- Return type implied by the statement around the call.
  function L.deduce_return(buf, call, hover)
    local pre = call.prefix
    -- find where the enclosing (sub)expression begins
    local cut = 0
    local stack = {}
    local i, n = 1, #pre
    while i <= n do
      local ch = pre:sub(i, i)
      local kind, j = lex.skip_special(pre, i)
      if kind then
        i = j
      else
        if ch == ";" or ch == "{" or ch == "}" then
          cut, stack = i, {}
        elseif ch == "(" then
          stack[#stack + 1] = { cut = cut, open = i }
          cut = i
        elseif ch == ")" then
          local top = table.remove(stack)
          if top then
            local head = pre:sub(1, top.open - 1):match("([%a_]+)%s*$")
            cut = CONTROL[head] and i or top.cut
          end
        elseif ch == "," or ch == "?" then
          cut = i
        elseif ch == ":" then
          if pre:sub(i + 1, i + 1) == ":" then
            i = i + 1
          elseif pre:sub(i - 1, i - 1) ~= ":" then
            cut = i
          end
        end
        i = i + 1
      end
    end
    local ctx_start = cut + 1
    local ctx, lead = util.trim_lead(pre:sub(ctx_start))
    ctx_start = ctx_start + lead
    local enclosing = stack[#stack]
    local head = enclosing and pre:sub(1, enclosing.open - 1):match("([%a_]+)%s*$")

    if ctx == "" or ctx == "else" or ctx == "do" then
      if enclosing then
        if CONTROL[head] then
          return spec.bool_type
        end
        return nil -- argument of another call
      end
      return "void" -- expression statement: the result is unused
    end
    if ctx == "return" or ctx == "co_return" then
      return return_type_of_enclosing(buf, call.row)
    end
    if ctx:match("!$") or ctx:match("&&$") or ctx:match("||$") then
      return spec.bool_type
    end

    local lhs, op = ctx:match("^(.-)%s*([<>][<>]=)$")
    if not lhs then
      lhs, op = ctx:match("^(.-)%s*([%+%-%*/%%&|%^]?=)$")
    end
    if not lhs or lhs == "" or lhs:match("[=!<>]$") then
      return nil
    end
    -- declaration: `T name = call(...)`
    if op == "=" then
      local ty = lhs:match("^(.-[%s%*&>])%s*[%a_][%w_]*$")
      if
        ty
        and ty:match("[%w_]")
        and not ty:find("[%.%[%(]")
        and not ty:find("->", 1, true)
        and not KEYWORDS[vim.trim(ty)]
      then
        return strip_storage(ty)
      end
    end
    -- assignment to an existing lvalue: ask the LSP
    local lhs_at = function(k)
      return call.prefix_at(ctx_start + k - 1)
    end
    local deref = lhs:match("^%*") ~= nil
    local subscript = lhs:match("%]$") ~= nil
    local target = lhs
    if subscript then
      local open = lex.matching_back(lhs, #lhs)
      target = open and lhs:sub(1, open - 1) or lhs
    end
    local id = target:find("[%a_][%w_]*%s*$")
    if not id then
      return nil
    end
    local t = hover_type(hover, lhs_at, id)
    if deref or subscript then
      t = F.strip_ptr(t)
    end
    return t
  end

  --- Builds the signature for `call`.
  ---@return { ret: string, name: string, params: { type: string, name: string }[] }
  function L.deduce_signature(buf, call, hover)
    local params = {}
    local used = {}
    for idx, a in ipairs(call.args) do
      local t = L.deduce_expr(a.text, a.at, hover) or unknown()
      local nm = arg_name(a.text) or ("arg" .. idx)
      if used[nm] then
        nm = nm .. idx
      end
      used[nm] = true
      params[#params + 1] = { type = F.pretty_type(t), name = nm }
    end
    return {
      ret = F.pretty_type(L.deduce_return(buf, call, hover) or unknown()),
      name = call.name,
      params = params,
    }
  end

  function L.format_prototype(sig)
    local ps = {}
    for _, p in ipairs(sig.params) do
      ps[#ps + 1] = join_type_name(p.type, p.name)
    end
    local plist = #ps > 0 and table.concat(ps, ", ") or spec.empty_params
    return join_type_name(sig.ret, sig.name) .. "(" .. plist .. ")"
  end

  require("effen.lang.c_wrap").install(L, F, spec)

  return L
end

return F
