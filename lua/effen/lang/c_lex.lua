-- Minimal lexical helpers for C-family source text. They understand comments,
-- string/char literals (incl. C++ raw strings) and bracket nesting, which is
-- all the plugin needs; no full parser and no treesitter dependency.
local M = {}

local OPEN = { ["("] = ")", ["["] = "]", ["{"] = "}" }
local CLOSE = { [")"] = true, ["]"] = true, ["}"] = true }

--- If `s` at `i` starts a comment or literal, returns kind and the index just
--- past it. Otherwise returns nil.
---@return "comment"|"string"|nil, integer?
function M.skip_special(s, i)
  local c = s:sub(i, i)
  if c == "/" then
    local d = s:sub(i + 1, i + 1)
    if d == "/" then
      local j = s:find("\n", i, true)
      return "comment", j or (#s + 1)
    elseif d == "*" then
      local j = s:find("*/", i + 2, true)
      return "comment", j and (j + 2) or (#s + 1)
    end
    return nil
  end
  if c ~= '"' and c ~= "'" then
    return nil
  end
  if c == "'" and s:sub(i - 1, i - 1):match("%d") then
    return nil -- C++14 digit separator: 1'000
  end
  if c == '"' and s:sub(i - 1, i - 1) == "R" then
    local delim = s:match('^"([^%(%s\\]*)%(', i)
    if delim then
      local close = ")" .. delim .. '"'
      local j = s:find(close, i, true)
      return "string", j and (j + #close) or (#s + 1)
    end
  end
  local j = i + 1
  while j <= #s do
    local ch = s:sub(j, j)
    if ch == "\\" then
      j = j + 2
    elseif ch == c then
      return "string", j + 1
    elseif ch == "\n" then
      return "string", j
    else
      j = j + 1
    end
  end
  return "string", j
end

--- Replaces comments by a single space.
function M.strip_comments(s)
  local out, i, n = {}, 1, #s
  local from = 1
  while i <= n do
    local kind, j = M.skip_special(s, i)
    if kind == "comment" then
      out[#out + 1] = s:sub(from, i - 1)
      out[#out + 1] = " "
      i, from = j, j
    elseif kind then
      i = j
    else
      i = i + 1
    end
  end
  out[#out + 1] = s:sub(from)
  return table.concat(out)
end

--- Index of the bracket matching the opener at `i` (one of `([{`, and `<`
--- when `angles` is set), or nil.
function M.matching(s, i, angles)
  local stack = {}
  local n = #s
  while i <= n do
    local c = s:sub(i, i)
    local kind, j = M.skip_special(s, i)
    if kind then
      i = j
    else
      if OPEN[c] then
        stack[#stack + 1] = OPEN[c]
      elseif angles and c == "<" then
        stack[#stack + 1] = ">"
      elseif CLOSE[c] or (angles and c == ">" and stack[#stack] == ">") then
        if stack[#stack] ~= c then
          return nil
        end
        stack[#stack] = nil
        if #stack == 0 then
          return i
        end
      end
      i = i + 1
    end
  end
end

--- Index of the opener matching the closing bracket at `j` (scans backwards;
--- does not understand string literals containing brackets).
function M.matching_back(s, j)
  local depth = 0
  for i = j, 1, -1 do
    local c = s:sub(i, i)
    if CLOSE[c] then
      depth = depth + 1
    elseif OPEN[c] then
      depth = depth - 1
      if depth == 0 then
        return i
      end
    end
  end
end

--- Splits `s` on top-level occurrences of the single character `sep`.
--- Returns a list of { from, to } index ranges (inclusive, may be empty).
function M.split_top(s, sep, angles)
  local parts = {}
  local depth = 0
  local from = 1
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local kind, j = M.skip_special(s, i)
    if kind then
      i = j
    else
      if OPEN[c] or (angles and c == "<") then
        depth = depth + 1
      elseif CLOSE[c] or (angles and c == ">" and depth > 0) then
        depth = depth - 1
      elseif c == sep and depth == 0 then
        parts[#parts + 1] = { from, i - 1 }
        from = i + 1
      end
      i = i + 1
    end
  end
  parts[#parts + 1] = { from, n }
  return parts
end

--- Index of the first top-level `=` that is an assignment/default (not part
--- of `==`, `<=`, `>=`, `!=`).
function M.find_top_assign(s, angles)
  local depth = 0
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local kind, j = M.skip_special(s, i)
    if kind then
      i = j
    else
      if OPEN[c] or (angles and c == "<") then
        depth = depth + 1
      elseif CLOSE[c] or (angles and c == ">" and depth > 0) then
        depth = depth - 1
      elseif c == "=" and depth == 0 then
        local prev, nxt = s:sub(i - 1, i - 1), s:sub(i + 1, i + 1)
        if nxt ~= "=" and not prev:match("[=!<>]") then
          return i
        end
        if nxt == "=" then
          i = i + 1
        end
      end
      i = i + 1
    end
  end
end

local OPS = {
  "<<=",
  ">>=",
  "->*",
  "...",
  "->",
  "++",
  "--",
  "<<",
  ">>",
  "<=",
  ">=",
  "==",
  "!=",
  "&&",
  "||",
  "::",
  "+=",
  "-=",
  "*=",
  "/=",
  "%=",
  "&=",
  "|=",
  "^=",
}

--- Tokenizes the top level of an expression into operators. Each entry is
--- { op = string, i = index, binary = bool } where `binary` means the
--- operator follows an operand (so it is not a prefix operator).
function M.top_ops(s)
  local ops = {}
  local prev_operand = false
  local i, n = 1, #s
  while i <= n do
    local c = s:sub(i, i)
    local kind, j = M.skip_special(s, i)
    if kind == "string" then
      prev_operand = true
      i = j
    elseif kind == "comment" then
      i = j
    elseif c:match("%s") then
      i = i + 1
    elseif c:match("%d") or (c == "." and s:sub(i + 1, i + 1):match("%d")) then
      local k = i
      while k <= n do
        local ch = s:sub(k, k)
        if ch:match("[%w_.']") then
          k = k + 1
        elseif (ch == "+" or ch == "-") and s:sub(k - 1, k - 1):match("[eEpP]") then
          k = k + 1
        else
          break
        end
      end
      prev_operand = true
      i = k
    elseif c:match("[%a_]") then
      local k = s:find("[^%w_]", i) or (n + 1)
      prev_operand = true
      i = k
    elseif OPEN[c] then
      -- a bracketed group (call args, subscript, cast, parenthesized expr)
      -- always leaves us right after an operand-like thing
      local close = M.matching(s, i)
      i = (close or n) + 1
      prev_operand = true
    else
      local op = c
      for _, cand in ipairs(OPS) do
        if s:sub(i, i + #cand - 1) == cand then
          op = cand
          break
        end
      end
      local binary = prev_operand
      if op == "++" or op == "--" then
        binary = false -- postfix/prefix increment keeps operand state
      else
        prev_operand = false
      end
      if op == "::" or op == "->" or op == "." or op == "->*" then
        prev_operand = false
        binary = false
      end
      ops[#ops + 1] = { op = op, i = i, binary = binary }
      i = i + #op
    end
  end
  return ops
end

local function op_at(s, i)
  for _, cand in ipairs(OPS) do
    if s:sub(i, i + #cand - 1) == cand then
      return cand
    end
  end
  return s:sub(i, i)
end

--- Splits `s` into tokens, skipping whitespace and comments. Each token is
--- { t = text, k = kind, i = first index, j = last index } with kind one of
--- "id", "num", "str" (string/char literal), "pp" (a whole preprocessor
--- line) or "op".
function M.tokens(s)
  local toks = {}
  local i, n = 1, #s
  local line_start = true
  local function add(k, a, b)
    toks[#toks + 1] = { t = s:sub(a, b), k = k, i = a, j = b }
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
          j = n
          break
        end
        if s:sub(e - 1, e - 1) == "\\" then
          j = e + 1
        else
          j = e - 1
          break
        end
      end
      add("pp", i, j)
      toks[#toks].t = vim.trim(toks[#toks].t)
      i = j + 1
    else
      line_start = false
      local kind, j = M.skip_special(s, i)
      if kind == "comment" then
        i = j
      elseif kind == "string" then
        add("str", i, j - 1)
        i = j
      elseif c:match("[%a_]") then
        local e = (s:find("[^%w_]", i) or (n + 1)) - 1
        local nx = s:sub(e + 1, e + 1)
        local k2, j2
        if (nx == '"' or nx == "'") and s:sub(i, e):match("^[LuU]?8?R?$") then
          k2, j2 = M.skip_special(s, e + 1) -- prefixed literal: L"..", u8R"(..)"
        end
        if k2 == "string" then
          add("str", i, j2 - 1)
          i = j2
        else
          add("id", i, e)
          i = e + 1
        end
      elseif c:match("%d") or (c == "." and s:sub(i + 1, i + 1):match("%d")) then
        local k = i
        while k <= n do
          local ch = s:sub(k, k)
          if ch:match("[%w_.']") then
            k = k + 1
          elseif (ch == "+" or ch == "-") and s:sub(k - 1, k - 1):match("[eEpP]") then
            k = k + 1
          else
            break
          end
        end
        add("num", i, k - 1)
        i = k
      else
        local op = op_at(s, i)
        add("op", i, i + #op - 1)
        i = i + #op
      end
    end
  end
  return toks
end

local TOK_OPEN = { ["("] = ")", ["["] = "]", ["{"] = "}" }

--- Index of the token closing the bracket token at `k`, or nil.
function M.token_match(toks, k)
  local stack = {}
  for m = k, #toks do
    local t = toks[m].t
    if TOK_OPEN[t] then
      stack[#stack + 1] = TOK_OPEN[t]
    elseif t == ")" or t == "]" or t == "}" then
      if stack[#stack] ~= t then
        return nil
      end
      stack[#stack] = nil
      if #stack == 0 then
        return m
      end
    end
  end
end

return M
