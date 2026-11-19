-- `wrap` (extract function) for C-like languages. Installed onto a language
-- object by c_family.new(); adds:
--   wrap_analyze(buf, region, env)    -> analysis | nil, err
--   wrap_signature(analysis, name)    -> sig (for format_prototype)
--   wrap_build(analysis, proto, indent) -> build | nil, err
--   wrap_find(lines, analysis, build, exclude) -> instances
--
-- A region is { srow, scol, erow, ecol, linewise } (0-based, ecol exclusive).
-- `env` = { hover = fn(row, col) -> hover info, locate = fn(row, col) ->
-- definition locations }; either may be nil (no LSP).
local lex = require("effen.lang.c_lex")
local util = require("effen.util")

local W = {}

local function set(list)
  local s = {}
  for _, v in ipairs(list) do
    s[v] = true
  end
  return s
end

-- identifiers that are never variables
local NOT_VARS = set({
  "NULL", "nullptr", "true", "false", "this", "if", "else", "while", "for", "do",
  "switch", "case", "default", "break", "continue", "return", "goto", "sizeof",
  "alignof", "_Alignof", "typedef", "struct", "union", "enum", "class", "template",
  "typename", "namespace", "using", "public", "private", "protected", "operator",
  "new", "delete", "static_assert", "_Static_assert", "co_return", "co_await",
  "co_yield", "throw", "try", "catch", "decltype", "typeof", "__typeof__",
  "noexcept", "asm", "__asm__", "__attribute__", "alignas", "_Alignas",
})
local TAGS = set({ "struct", "union", "enum", "class", "typename" })
local ASSIGN = set({ "=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=" })
local LOOPS = set({ "for", "while", "do", "switch" })
local DECL_END = set({ "=", ";", ",", "[", ":" })
local LITERAL_IDS = set({ "NULL", "nullptr", "true", "false" })

-- token contexts accepted around a copy of a wrapped expression / statement
local EXPR_PREV = set({
  "(", "[", ",", "=", "+=", "-=", "*=", "/=", "%=", "&=", "|=", "^=", "<<=", ">>=",
  "return", "co_return", "throw", "case", "?", ":", "{", ";", "}",
})
local EXPR_NEXT = set({ ")", "]", ",", ";", "?", ":", "}" })
local POSTFIX = set({ ".", "->", "[", "(", "++", "--", "::" })
local STMT_PREV = set({ ";", "{", "}" })

function W.install(L, F, spec)
  local function unknown()
    return require("effen.config").get().unknown_type
  end

  local function is_name(t)
    return t ~= nil and t.k == "id" and not F.TYPE_WORDS[t.t] and not F.STORAGE[t.t] and not NOT_VARS[t.t]
  end

  local function operand_end(t)
    return t ~= nil and ((t.k == "id" and not NOT_VARS[t.t]) or t.k == "num" or t.k == "str" or t.t == ")" or t.t == "]")
  end

  --- Token k names a variable (not a member, tag, label, case constant or
  --- qualifier).
  local function var_ref(toks, k)
    local t = toks[k]
    if not is_name(t) then
      return false
    end
    local p, nx = toks[k - 1], toks[k + 1]
    if p and (p.t == "." or p.t == "->" or p.t == "::" or p.t == "goto" or p.t == "case" or TAGS[p.t]) then
      return false
    end
    if nx and nx.t == "::" then
      return false
    end
    if nx and nx.t == ":" and (not p or STMT_PREV[p.t]) then
      return false -- label
    end
    return true
  end

  --- `x` at token k is assigned, incremented, has its address taken or (C++)
  --- gets a method called on it, so a by-value parameter would lose the change.
  local function is_write(toks, k)
    local p, nx = toks[k - 1], toks[k + 1]
    if p and (p.t == "++" or p.t == "--") then
      return true
    end
    if p and p.t == "&" and not operand_end(toks[k - 2]) then
      return true
    end
    if nx and (ASSIGN[nx.t] or nx.t == "++" or nx.t == "--") then
      return true
    end
    if nx and nx.t == "." then -- member of a value: s.a.b[i] = ...
      local j = k + 1
      while toks[j] and toks[j].t == "." and toks[j + 1] and toks[j + 1].k == "id" do
        j = j + 2
        while toks[j] and toks[j].t == "[" do
          local close = lex.token_match(toks, j)
          if not close then
            return false
          end
          j = close + 1
        end
      end
      local t = toks[j]
      if t and (ASSIGN[t.t] or t.t == "++" or t.t == "--") then
        return true
      end
      if spec.references and t and t.t == "(" then
        return true
      end
    end
    return false
  end

  local function join_tokens(toks, a, b)
    local out = {}
    for m = a, b do
      local t = toks[m].t
      local prev = out[#out]
      if prev and not (t == "::" or t == "<" or t == ">" or t == "," or prev:match("[:<]$")) then
        out[#out + 1] = " "
      end
      out[#out + 1] = t
    end
    return table.concat(out)
  end

  local function valid_base(toks, a, b)
    if b < a or not toks[a] or (toks[a].k == "id" and NOT_VARS[toks[a].t] and not TAGS[toks[a].t]) then
      return false
    end
    local angle, ids = 0, 0
    for m = a, b do
      local t = toks[m]
      if t.k == "id" then
        if NOT_VARS[t.t] and not TAGS[t.t] then
          return false
        end
        ids = ids + 1
      elseif t.t == "<" then
        angle = angle + 1
      elseif t.t == ">" then
        angle = angle - 1
        if angle < 0 then
          return false
        end
      elseif t.t == "::" then -- qualified type
      elseif angle > 0 and (t.t == "," or t.t == "*" or t.t == "&" or t.k == "num") then
      else
        return false
      end
    end
    local last = toks[b]
    return angle == 0 and ids > 0 and (last.k == "id" or last.t == ">") and not TAGS[last.t]
  end

  --- Variables declared in `toks` (heuristic, no symbol table): list of
  --- { name, k = token index, type|nil }.
  local function declarations(toks)
    local out = {}
    local start, base, base_depth = 1, nil, nil
    local depth = 0
    for k, t in ipairs(toks) do
      local tt = t.t
      if tt == ";" or tt == "{" or tt == "}" then
        start, base = k + 1, nil
      elseif tt == "(" or tt == "[" then
        local p = toks[k - 1]
        depth = depth + 1
        if tt == "(" and p and (p.t == "for" or p.t == "if" or p.t == "while" or p.t == "switch") then
          start, base = k + 1, nil
        end
      elseif tt == ")" or tt == "]" then
        depth = depth - 1
      elseif is_name(t) and toks[k + 1] and DECL_END[toks[k + 1].t] then
        local m = k - 1
        while toks[m] and (toks[m].t == "*" or toks[m].t == "&" or toks[m].t == "&&") do
          m = m - 1
        end
        local ptr = m + 1 <= k - 1 and join_tokens(toks, m + 1, k - 1) or ""
        local ty
        if toks[m] and toks[m].t == "," and base and depth == base_depth then
          ty = base .. " " .. ptr
        elseif m >= start and valid_base(toks, start, m) then
          base, base_depth = join_tokens(toks, start, m), depth
          ty = base .. " " .. ptr
        end
        if ty then
          if toks[k + 1].t == "[" then
            ty = F.add_ptr(ty) -- arrays decay
          end
          out[#out + 1] = { name = t.t, k = k, type = F.strip_storage(ty) }
        end
      end
    end
    return out
  end

  local function hover_type(env, row, col)
    if not env.hover then
      return nil
    end
    local info = env.hover(row, col)
    return info and info.type and F.clean_type(info.type)
  end

  ------------------------------------------------------------------------------
  -- Analysis
  ------------------------------------------------------------------------------

  function L.wrap_analyze(buf, r, env)
    env = env or {}
    local all = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local d
    for _, x in ipairs(F.definitions(all)) do
      local after_open = r.srow > x.erow or (r.srow == x.erow and r.scol > x.ecol)
      if after_open and (x.body_end_row or x.erow) >= r.erow then
        d = x
        break
      end
    end
    if not d then
      return nil, "the selection must be inside a function body"
    end

    local function line_at(row)
      return all[row + 1] or ""
    end
    local rl = vim.api.nvim_buf_get_text(buf, r.srow, r.scol, r.erow, r.ecol, {})
    local text = table.concat(rl, "\n")
    local RT = util.text(rl, r.srow)
    local function pos(i)
      local row, col = RT.pos(i)
      if row == r.srow then
        col = col + r.scol
      end
      return row, col
    end
    local toks = lex.tokens(text)
    if #toks == 0 then
      return nil, "the selection is empty"
    end

    -- shape: balanced; statements end with `;`/`}`, expressions have no `;`
    local depth, starts = 0, { 1 }
    for k, t in ipairs(toks) do
      if t.t == "(" or t.t == "[" or t.t == "{" then
        depth = depth + 1
      elseif t.t == ")" or t.t == "]" or t.t == "}" then
        depth = depth - 1
        if depth < 0 then
          return nil, "the selection has unbalanced brackets"
        end
      end
      if depth == 0 and (t.t == ";" or t.t == "}") and k < #toks then
        starts[#starts + 1] = k + 1
      end
    end
    if depth ~= 0 then
      return nil, "the selection has unbalanced brackets"
    end
    local last = toks[#toks].t
    local mode = (last == ";" or last == "}") and "stmt" or "expr"
    if mode == "expr" then
      if r.linewise then
        return nil, "a line selection must end with `;` or `}`"
      end
      if #starts > 1 then
        return nil, "select a complete expression or complete statements"
      end
    end

    -- candidate identifiers in order of first use
    local cand, order = {}, {}
    for k = 1, #toks do
      if var_ref(toks, k) then
        local nm = toks[k].t
        if not cand[nm] then
          cand[nm] = { name = nm, first = k, occ = {} }
          order[#order + 1] = nm
        end
        table.insert(cand[nm].occ, k)
      end
    end

    local inner_decls = declarations(toks)
    local inner = {}
    for _, x in ipairs(inner_decls) do
      inner[x.name] = inner[x.name] or x
    end
    local outer = {}
    for _, prm in ipairs(d.proto.params) do
      if prm.name then
        outer[prm.name] = { type = F.clean_type(prm.type) }
      end
    end
    local before = vim.api.nvim_buf_get_text(buf, d.erow, d.ecol + 1, r.srow, r.scol, {})
    for _, x in ipairs(declarations(lex.tokens(table.concat(before, "\n")))) do
      outer[x.name] = { type = x.type }
    end

    -- hover with a fallback to the declarations seen above (no LSP needed)
    local hover = function(row, col)
      local info = env.hover and env.hover(row, col)
      if info and (info.type or info.ret) then
        return info
      end
      local word = (all[row + 1] or ""):sub(col + 1):match("^[%a_][%w_]*")
      local x = word and (inner[word] or outer[word])
      return x and x.type and { kind = "variable", type = x.type } or info
    end

    local here = util.abspath(vim.api.nvim_buf_get_name(buf))
    local function classify(c)
      if env.locate then
        local locs = env.locate(pos(toks[c.first].i))
        if locs and #locs > 0 then
          local l = locs[1]
          if util.abspath(l.path) ~= here then
            return "global"
          end
          local before_start = l.row < r.srow or (l.row == r.srow and l.col < r.scol)
          local after_end = l.row > r.erow or (l.row == r.erow and l.col >= r.ecol)
          if not before_start and not after_end then
            return "inner"
          end
          if before_start and l.row >= d.srow then
            return "outer"
          end
          return "global"
        end
      end
      if inner[c.name] and inner[c.name].k <= c.first then
        return "inner"
      end
      if outer[c.name] then
        return "outer"
      end
      return "global"
    end

    local vars, occ_var, occ_local, locals = {}, {}, {}, {}
    for _, nm in ipairs(order) do
      local c = cand[nm]
      local kind = classify(c)
      if kind == "outer" then
        local ty = outer[nm] and outer[nm].type or hover_type(env, pos(toks[c.first].i))
        local v = { name = nm, type = ty or unknown(), known = ty ~= nil, out = false }
        for _, k in ipairs(c.occ) do
          v.out = v.out or is_write(toks, k)
          occ_var[k] = #vars + 1
        end
        vars[#vars + 1] = v
      elseif kind == "inner" then
        local ty = inner[nm] and inner[nm].type or hover_type(env, pos(toks[c.first].i))
        locals[nm] = { name = nm, type = ty }
        for _, k in ipairs(c.occ) do
          occ_local[k] = nm
        end
      end
    end

    local an = {
      mode = mode,
      region = r,
      text = text,
      toks = toks,
      vars = vars,
      occ_var = occ_var,
      warnings = {},
      single = #starts == 1,
      enclosing = d.proto.base,
    }
    local line = line_at(r.srow)
    an.lead = util.is_blank(line:sub(1, r.scol)) and line:sub(1, r.scol) or ""

    -- return value
    local ret
    if mode == "expr" then
      ret = L.deduce_expr(text, function(k)
        return pos(k)
      end, hover)
      if not ret then -- from the context: `T v = <sel>`, `return <sel>`, `if (<sel>)`
        local PT = util.text({ line_at(r.srow):sub(1, r.scol) }, r.srow)
        local ctx_ret = L.deduce_return(buf, { row = r.srow, prefix = PT.str, prefix_at = PT.pos }, hover)
        ret = ctx_ret ~= "void" and ctx_ret or nil
      end
      local ops = lex.top_ops(text)
      an.primary = toks[1].k ~= "op" or toks[1].t == "("
      for _, op in ipairs(ops) do
        if op.binary or not (op.op == "." or op.op == "->" or op.op == "::") then
          an.primary = false
        end
      end
    else
      local tail = toks[starts[#starts]]
      if tail.t == "return" then
        an.tail = toks[starts[#starts] + 1].t == ";" and "void" or "expr"
        ret = an.tail == "expr" and F.strip_storage(d.proto.prefix) or "void"
      end
      for k, t in ipairs(toks) do
        if t.t == "return" and k ~= starts[#starts] then
          an.warnings[#an.warnings + 1] = "the selection has an early `return`; it now only leaves the new function"
          break
        end
      end
      local has = {}
      for _, t in ipairs(toks) do
        has[t.t] = true
      end
      local loop = false
      for w in pairs(LOOPS) do
        loop = loop or has[w]
      end
      if (has["break"] or has["continue"]) and not loop then
        an.warnings[#an.warnings + 1] = "`break`/`continue` in the selection belong to a loop outside it"
      end
      if has["goto"] then
        an.warnings[#an.warnings + 1] = "`goto` in the selection may jump outside the new function"
      end

      if not an.tail then
        local eline = all[d.body_end_row + 1] or ""
        local after = vim.api.nvim_buf_get_text(buf, r.erow, r.ecol, d.body_end_row, #eline, {})
        local atoks = lex.tokens(table.concat(after, "\n"))
        local used_after = {}
        for k = 1, #atoks do
          if var_ref(atoks, k) then
            used_after[atoks[k].t] = true
          end
        end
        local returned, seen = {}, {}
        for _, x in ipairs(inner_decls) do
          if locals[x.name] and used_after[x.name] and not seen[x.name] then
            seen[x.name] = true
            returned[#returned + 1] = x.name
          end
        end
        if #returned > 0 then
          an.returned = returned[1]
          ret = locals[an.returned].type
          if #returned > 1 then
            an.warnings[#an.warnings + 1] = table.concat(returned, ", ", 2)
              .. " are declared in the selection and used after it; only "
              .. returned[1]
              .. " is returned"
          end
        else
          ret = "void"
        end
      end
    end
    an.ret = F.pretty_type(ret or unknown())

    -- pattern for finding copies: variables become wildcards
    local pattern, anchor = {}, nil
    for k, t in ipairs(toks) do
      if occ_var[k] then
        pattern[k] = { w = "p", v = occ_var[k] }
      elseif occ_local[k] then
        pattern[k] = { w = "l", name = occ_local[k] }
      else
        pattern[k] = { t = t.t }
        if (t.k == "id" or t.k == "str" or t.k == "num") and #t.t > 1 and (not anchor or #t.t > #anchor) then
          anchor = t.t
        end
      end
    end
    an.pattern, an.anchor = pattern, anchor
    return an
  end

  --- Default signature: out-parameters become pointers (C) or references (C++).
  function L.wrap_signature(an, name)
    local params = {}
    for _, v in ipairs(an.vars) do
      local t = v.type
      if v.out then
        t = spec.references and F.pretty_type(t .. " &") or F.add_ptr(t)
      end
      params[#params + 1] = { type = t, name = v.name }
    end
    return { ret = an.ret, name = name, params = params }
  end

  ------------------------------------------------------------------------------
  -- Building
  ------------------------------------------------------------------------------

  --- Matches the prototype's parameters to the analysed variables: by name,
  --- then by position among the remaining ones (renamed parameters).
  local function map_params(an, p)
    local by_name, used, map = {}, {}, {}
    for i, v in ipairs(an.vars) do
      by_name[v.name] = i
    end
    local real = {}
    for i, prm in ipairs(p.params) do
      if prm.name and prm.type ~= "void" and prm.type ~= "..." then
        real[#real + 1] = i
        local vi = by_name[prm.name]
        if vi and not used[vi] then
          map[i], used[vi] = vi, true
        end
      end
    end
    local free = {}
    for i = 1, #an.vars do
      if not used[i] then
        free[#free + 1] = i
      end
    end
    local f = 1
    for _, i in ipairs(real) do
      if not map[i] and free[f] then
        map[i], f = free[f], f + 1
      end
    end
    return map, real
  end

  local function dedent(lines, indent)
    local common
    for _, l in ipairs(lines) do
      if not util.is_blank(l) then
        local ws = l:match("^%s*")
        if not common then
          common = ws
        else
          local n = 0
          while n < #common and n < #ws and common:sub(n + 1, n + 1) == ws:sub(n + 1, n + 1) do
            n = n + 1
          end
          common = common:sub(1, n)
        end
      end
    end
    local out = {}
    for _, l in ipairs(lines) do
      out[#out + 1] = util.is_blank(l) and "" or indent .. l:sub(#(common or "") + 1):gsub("%s+$", "")
    end
    while #out > 0 and out[1] == "" do
      table.remove(out, 1)
    end
    while #out > 0 and out[#out] == "" do
      table.remove(out)
    end
    return out
  end

  --- Builds the new function's body and the call replacing the selection,
  --- following the (possibly edited) prototype.
  function L.wrap_build(an, proto_text, indent)
    local p = F.parse_proto(proto_text)
    if not p then
      return nil, "could not parse prototype: " .. proto_text
    end
    local map, real = map_params(an, p)
    local rtype = F.strip_storage(p.prefix) or "auto"
    local is_void = F.normalize_type(rtype) == "void"

    local params, lvalue = {}, {}
    for i, vi in pairs(map) do
      local v, prm = an.vars[vi], p.params[i]
      local pt = F.normalize_type(prm.type)
      local deref = pt == F.normalize_type(F.add_ptr(v.type)) or (not v.known and v.out and pt:match("%*$") ~= nil)
      params[vi] = { name = prm.name, deref = deref }
      lvalue[vi] = deref or v.out
    end

    -- body: rename parameters, dereference new pointer parameters
    local toks, edits = an.toks, {}
    for k, vi in pairs(an.occ_var) do
      local prm = params[vi]
      if prm then
        local t, prev, nx = toks[k], toks[k - 1], toks[k + 1]
        if prm.deref then
          if prev and prev.t == "&" and not operand_end(toks[k - 2]) and not (nx and POSTFIX[nx.t]) then
            edits[#edits + 1] = { prev.i, t.j, prm.name }
          elseif nx and nx.t == "." then
            edits[#edits + 1] = { t.i, nx.j, prm.name .. "->" }
          else
            edits[#edits + 1] = { t.i, t.j, "(*" .. prm.name .. ")" }
          end
        elseif prm.name ~= t.t then
          edits[#edits + 1] = { t.i, t.j, prm.name }
        end
      end
    end
    table.sort(edits, function(a, b)
      return a[1] > b[1]
    end)
    local text = an.text
    for _, e in ipairs(edits) do
      text = text:sub(1, e[1] - 1) .. e[3] .. text:sub(e[2] + 1)
    end
    local raw = vim.split(text, "\n", { plain = true })
    raw[1] = an.lead .. raw[1]
    local body = dedent(raw, indent)
    if an.mode == "expr" then
      if not is_void then
        body[1] = indent .. "return " .. body[1]:sub(#indent + 1)
      end
      body[#body] = body[#body] .. ";"
    elseif an.returned and not is_void then
      body[#body + 1] = indent .. "return " .. an.returned .. ";"
    end

    local function call(arg_for)
      local args = {}
      for _, i in ipairs(real) do
        local vi = map[i]
        args[#args + 1] = (vi and arg_for(vi, params[vi].deref)) or p.params[i].name
      end
      return p.base .. "(" .. table.concat(args, ", ") .. ")"
    end
    local function statements(c, ret_name)
      if an.mode == "expr" then
        return { c }
      elseif an.tail == "expr" then
        return { "return " .. c .. ";" }
      elseif an.tail == "void" then
        return { c .. ";", "return;" }
      elseif ret_name and not is_void then
        return { F.join_type_name(rtype, ret_name) .. " = " .. c .. ";" }
      end
      return { c .. ";" }
    end

    return {
      proto = p,
      body = body,
      lvalue = lvalue,
      replacement = statements(call(function(vi, deref)
        local n = an.vars[vi].name
        return deref and ("&" .. n) or n
      end), an.returned),
      --- replacement statements for a copy with the given bindings
      instance = function(bind)
        return statements(
          call(function(vi, deref)
            local b = bind.p[vi]
            return b and (deref and ("&" .. b) or b)
          end),
          an.returned and bind.l[an.returned]
        )
      end,
    }
  end

  ------------------------------------------------------------------------------
  -- Finding copies
  ------------------------------------------------------------------------------

  --- Copies of the wrapped code in `lines`, the variables possibly renamed.
  --- `exclude` = { first_row, last_row } (the new definition).
  ---@return { srow, scol, erow, ecol, lines: string[] }[]
  function L.wrap_find(lines, an, bld, exclude)
    local text = table.concat(lines, "\n")
    if an.anchor and not text:find(an.anchor, 1, true) then
      return {}
    end
    local toks = lex.tokens(text)
    local T = util.text(lines)
    local pat, np = an.pattern, #an.pattern

    local function boundary_ok(k)
      local prev, nxt = toks[k - 1], toks[k + np]
      if an.mode == "stmt" then
        if nxt and nxt.t == "else" then
          return false
        end
        if not prev or prev.k == "pp" or STMT_PREV[prev.t] then
          return true
        end
        if an.single and (prev.t == ")" or prev.t == "else" or prev.t == "do") then
          return true
        end
        if prev.t == ":" then
          local p2, p3 = toks[k - 2], toks[k - 3]
          return (p2 and p2.t == "default") or (p3 and p3.t == "case") or false
        end
        return false
      end
      if prev and (prev.t == "." or prev.t == "->" or prev.t == "::") then
        return false
      end
      local last = pat[np]
      if nxt and POSTFIX[nxt.t] and (last.w or toks[k + np - 1].k ~= "op") then
        return false
      end
      if an.primary then
        if prev and prev.k == "id" and not EXPR_PREV[prev.t] then
          return false -- `if (...)`, a call's argument list, a declaration
        end
        return not (pat[1].t == "(" and prev and prev.t == "]")
      end
      return (not prev or EXPR_PREV[prev.t] or false) and (not nxt or EXPR_NEXT[nxt.t] or false)
    end

    local function try_at(k)
      local bp, bl, taken = {}, {}, {}
      for m = 1, np do
        local pt, ft = pat[m], toks[k + m - 1]
        if pt.w == "p" then
          local ok = is_name(ft)
            or (not bld.lvalue[pt.v] and (ft.k == "num" or ft.k == "str" or LITERAL_IDS[ft.t] ~= nil))
          if not ok or (bp[pt.v] and bp[pt.v] ~= ft.t) then
            return nil
          end
          bp[pt.v] = ft.t
        elseif pt.w == "l" then
          if not is_name(ft) then
            return nil
          end
          if bl[pt.name] then
            if bl[pt.name] ~= ft.t then
              return nil
            end
          else
            if taken[ft.t] then
              return nil
            end
            bl[pt.name], taken[ft.t] = ft.t, true
          end
        elseif pt.t ~= ft.t then
          return nil
        end
      end
      if not boundary_ok(k) then
        return nil
      end
      -- locals of the copy (other than the returned one) must not be used later
      local check = {}
      for nm, b in pairs(bl) do
        if nm ~= an.returned then
          check[b] = true
        end
      end
      if next(check) then
        local depth = 0
        for m = k + np, #toks do
          local t = toks[m]
          if t.t == "{" then
            depth = depth + 1
          elseif t.t == "}" then
            depth = depth - 1
            if depth < 0 then
              break
            end
          elseif check[t.t] and var_ref(toks, m) then
            return nil
          end
        end
      end
      return { p = bp, l = bl }
    end

    local out = {}
    local k = 1
    while k + np - 1 <= #toks do
      local bind = try_at(k)
      if bind then
        local sr, sc = T.pos(toks[k].i)
        local er, ec = T.pos(toks[k + np - 1].j)
        if not (exclude and sr >= exclude[1] and sr <= exclude[2]) then
          out[#out + 1] = { srow = sr, scol = sc, erow = er, ecol = ec + 1, lines = bld.instance(bind) }
        end
        k = k + np
      else
        k = k + 1
      end
    end
    return out
  end
end

return W
