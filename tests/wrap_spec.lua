-- `wrap` without an LSP (declarations are found textually).
local c = require("effen.lang.c")
local cpp = require("effen.lang.cpp")
require("effen.config").setup({})

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local n = 0
local function file(lines, ext)
  n = n + 1
  local path = ("%s/f%d.%s"):format(dir, n, ext or "c")
  vim.fn.writefile(lines, path)
  vim.cmd("edit " .. path)
  vim.bo.expandtab, vim.bo.shiftwidth = true, 4
  return vim.api.nvim_get_current_buf(), path
end

--- region of the first occurrence of `text` (may span lines) in `buf`
local function region_of(buf, text, linewise)
  local all = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  local s = assert(all:find(text, 1, true), "not found: " .. text)
  local T = require("effen.util").text(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local srow, scol = T.pos(s)
  local erow, ecol = T.pos(s + #text - 1)
  if linewise then
    local last = vim.api.nvim_buf_get_lines(buf, erow, erow + 1, false)[1]
    return { srow = srow, scol = 0, erow = erow, ecol = #last, linewise = true }
  end
  return { srow = srow, scol = scol, erow = erow, ecol = ecol + 1 }
end

local function proto(lang, buf, r)
  local an = assert(lang.wrap_analyze(buf, r, {}))
  return lang.format_prototype(lang.wrap_signature(an, "fn")), an
end

local function lines(buf)
  return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

local function has(ls, s)
  return vim.tbl_contains(ls, s)
end

describe("wrap analysis", function()
  it("expression: outer locals become parameters, type from the expression", function()
    local buf = file({ "int main(void) {", "  int a = 2, b = 3;", "  long r = a * b + 1;", "  return 0;", "}" })
    local p, an = proto(c, buf, region_of(buf, "a * b + 1"))
    eq("int fn(int a, int b)", p)
    eq("expr", an.mode)
  end)

  it("statements: written variables become pointers in C", function()
    local buf = file({
      "void f(int count, const char *name) {",
      "  int total = 0;",
      "  total += count;",
      "  printf(\"%s\", name);",
      "  g(total);",
      "}",
    })
    local r = region_of(buf, "  total += count;\n  printf(\"%s\", name);", true)
    local p, an = proto(c, buf, r)
    eq("void fn(int *total, int count, const char *name)", p)
    local bld = assert(c.wrap_build(an, "void fn(int *total, int count, const char *name)", "    "))
    eq({ "    (*total) += count;", '    printf("%s", name);' }, bld.body)
    eq({ "fn(&total, count, name);" }, bld.replacement)
  end)

  it("struct members through a new pointer use ->, &x becomes x", function()
    local buf = file({
      "void f(void) {",
      "  struct point pt;",
      "  pt.x = 1;",
      "  scanf(\"%d\", &pt.y);",
      "  read_into(&pt);",
      "}",
    })
    local r = region_of(buf, "  pt.x = 1;\n  scanf(\"%d\", &pt.y);\n  read_into(&pt);", true)
    local p, an = proto(c, buf, r)
    eq("void fn(struct point *pt)", p)
    local bld = assert(c.wrap_build(an, p, "  "))
    eq({ "  pt->x = 1;", '  scanf("%d", &pt->y);', "  read_into(pt);" }, bld.body)
  end)

  it("C++: written variables and method calls become references", function()
    local buf = file({
      "void f(std::vector<int> v, int x) {",
      "  v.push_back(x);",
      "  use(v);",
      "}",
    }, "cpp")
    eq("void fn(std::vector<int> &v, int x)", (proto(cpp, buf, region_of(buf, "  v.push_back(x);", true))))
  end)

  it("a local used after the selection is returned", function()
    local buf = file({ "int f(int n) {", "  int sq = n * n;", "  int r = sq + 1;", "  return r;", "}" })
    local p, an = proto(c, buf, region_of(buf, "  int sq = n * n;", true))
    eq("int fn(int n)", p)
    local bld = assert(c.wrap_build(an, "int square(int v)", "  "))
    eq({ "  int sq = v * v;", "  return sq;" }, bld.body)
    eq({ "int sq = square(n);" }, bld.replacement)
  end)

  it("a trailing return returns the enclosing function's type", function()
    local buf = file({ "double f(int n) {", "  int sq = n * n;", "  double r = sq + 0.5;", "  return r;", "}" })
    local p, an = proto(c, buf, region_of(buf, "  double r = sq + 0.5;\n  return r;", true))
    eq("double fn(int sq)", p)
    eq({ "return fn(sq);" }, assert(c.wrap_build(an, p, "  ")).replacement)
  end)

  it("rejects selections outside a function or unbalanced", function()
    local buf = file({ "int g = 1;", "int f(void) {", "  if (g) {", "    g = 2;", "  }", "  return g;", "}" })
    eq(nil, (c.wrap_analyze(buf, region_of(buf, "int g = 1;"), {})))
    local _, err = c.wrap_analyze(buf, region_of(buf, "  if (g) {\n    g = 2;", true), {})
    eq("the selection has unbalanced brackets", err)
  end)

  it("globals and called functions are not parameters", function()
    local buf = file({ "int g = 1;", "int f(int k) {", "  int z = helper(g, k) + MAX;", "  return z;", "}" })
    eq("int fn(int k)", (proto(c, buf, region_of(buf, "helper(g, k) + MAX"))))
  end)
end)

describe("wrap: finding copies", function()
  it("matches copies with renamed variables, respecting precedence", function()
    local buf = file({
      "int f(int a, int b, int c, int d) {",
      "  int r = a * b + 1;",
      "  r += c * d + 1;",
      "  r += 2 * c * d + 1;", -- `c * d + 1` is not a subexpression here
      "  r += (a * b + 1) * 2;",
      "  return r;",
      "}",
    })
    local _, an = proto(c, buf, region_of(buf, "a * b + 1"))
    local bld = assert(c.wrap_build(an, "int mad(int a, int b)", "  "))
    local hits = c.wrap_find(lines(buf), an, bld)
    local got = {}
    for _, h in ipairs(hits) do
      got[#got + 1] = { h.srow, table.concat(h.lines, " ") }
    end
    eq({ { 1, "mad(a, b)" }, { 2, "mad(c, d)" }, { 4, "mad(a, b)" } }, got)
  end)

  it("statement copies: local renamed, not used afterwards", function()
    local buf = file({
      "void f(int *out, int n, int m) {",
      "  int t = n * 2;",
      "  out[0] = t;",
      "  int u = m * 2;",
      "  out[1] = u;",
      "  int w = n * 2;",
      "  out[2] = w;",
      "  use(w);",
      "}",
    })
    local r = region_of(buf, "  int t = n * 2;\n  out[0] = t;", true)
    local p, an = proto(c, buf, r)
    eq("void fn(int n, int *out)", p)
    local bld = assert(c.wrap_build(an, p, "  "))
    local hits = c.wrap_find(lines(buf), an, bld)
    eq(1, #hits) -- `out[1]` differs, `w` is used afterwards
    eq(1, hits[1].srow)
  end)
end)

describe("wrap: end to end", function()
  it("replaces the selection, appends the definition, replaces copies in the project", function()
    vim.fn.writefile({ "all:" }, dir .. "/Makefile")
    vim.fn.mkdir(dir .. "/proj", "p")
    vim.cmd("cd " .. dir .. "/proj")
    vim.fn.writefile({ "all:" }, dir .. "/proj/Makefile")
    vim.fn.writefile({
      "#include <stdio.h>",
      "",
      "void other(int p, int q) {",
      "  printf(\"%d\\n\", p * q + 1);",
      "}",
    }, dir .. "/proj/other.c")
    vim.cmd("edit " .. dir .. "/proj/main.c")
    local buf = vim.api.nvim_get_current_buf()
    vim.bo.expandtab, vim.bo.shiftwidth = true, 4
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "#include <stdio.h>",
      "",
      "int main(void) {",
      "  int a = 2, b = 3;",
      "  int x = a * b + 1;",
      "  int y = b * a + 1;",
      "  return x + y;",
      "}",
    })
    vim.cmd("write")
    require("effen.wrap").run({
      region = region_of(buf, "a * b + 1"),
      keys = "l",
      prototype = "int mad(int a, int b)",
      replace = "project",
    })
    local ls = lines(buf)
    eq(true, has(ls, "int mad(int a, int b);"), vim.inspect(ls))
    eq(true, has(ls, "  int x = mad(a, b);"), vim.inspect(ls))
    eq(true, has(ls, "  int y = mad(b, a);"), vim.inspect(ls))
    eq({ "int mad(int a, int b)", "{", "    return a * b + 1;", "}" }, vim.list_slice(ls, #ls - 3, #ls))
    local other = vim.fn.readfile(dir .. "/proj/other.c")
    eq(true, has(other, '  printf("%d\\n", mad(p, q));'), vim.inspect(other))
    eq(true, has(other, "int mad(int a, int b);"), vim.inspect(other))
    eq(2, #vim.fn.getqflist()) -- the copies, not the original selection
  end)
end)

vim.fn.delete(dir, "rf")
