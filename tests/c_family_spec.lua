local c = require("effen.lang.c")
local cpp = require("effen.lang.cpp")
require("effen.config").setup({})

local function scratch(lines, ft)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].filetype = ft or "c"
  return buf
end

-- fake hover: maps identifier names to types
local function hover_from(buf, types)
  return function(row, col)
    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
    local word = line:sub(col + 1):match("^[%w_]+")
    local t = types[word]
    if type(t) == "table" then
      return t
    end
    return t and { kind = "variable", type = t } or nil
  end
end

local function proto_for(lines, row, col, types, lang)
  lang = lang or c
  local buf = scratch(lines, lang.name)
  local call = assert(lang.parse_call(buf, row, col))
  return lang.format_prototype(lang.deduce_signature(buf, call, hover_from(buf, types or {})))
end

describe("parse_proto", function()
  it("parses a simple prototype", function()
    local p = c.parse_proto("static int foo(int a, const char *b)")
    eq("static int", p.prefix)
    eq("foo", p.name)
    eq({ "int", "const char*" }, c.param_types(p))
    eq("b", p.params[2].name)
  end)
  it("handles pointers, arrays, function pointers and defaults", function()
    local p = cpp.parse_proto("char *make(int arr[10], void (*cb)(int), std::map<int, int> m = {}, unsigned int)")
    eq("char *", p.prefix)
    eq("make", p.name)
    eq("arr", p.params[1].name)
    eq("int[10]", c.normalize_type(p.params[1].type))
    eq("cb", p.params[2].name)
    eq("m", p.params[3].name)
    eq("{}", p.params[3].default)
    eq(nil, p.params[4].name)
    eq("unsigned int", p.params[4].type)
  end)
  it("skips attributes and rejects non-functions", function()
    eq("foo", c.parse_proto("__attribute__((unused)) static int foo(void)").name)
    eq(0, #c.parse_proto("int foo(void)").params)
    eq(nil, c.parse_proto("int x = bar(3)"))
    eq(nil, c.parse_proto("typedef int (*fn)(int)"))
    eq(nil, c.parse_proto('MODULE_LICENSE("GPL")'))
  end)
  it("returns struct values", function()
    eq("struct point", c.parse_proto("struct point mid(struct point a, struct point b)").prefix)
  end)
end)

describe("scan", function()
  it("finds definitions and declarations", function()
    local lines = {
      "#include <stdio.h>",
      "/* comment with { brace */",
      "int add(int a, int b);",
      "struct s { int x; };",
      "namespace ns {",
      "int sub(int a,",
      "        int b) // trailing",
      "{",
      '  const char *s = "}";',
      "  return a - b;",
      "}",
      "}",
      "static int g = 3;",
    }
    local defs = cpp.definitions(lines)
    eq(1, #defs)
    eq("sub", defs[1].proto.name)
    eq(5, defs[1].srow)
    eq(7, defs[1].erow)
    eq(10, defs[1].body_end_row)
    local decls = cpp.declarations(lines)
    eq(1, #decls)
    eq("add", decls[1].proto.name)
    eq({ 2, 0, 2, 21 }, { decls[1].srow, decls[1].scol, decls[1].erow, decls[1].ecol })
  end)
end)

describe("literal types", function()
  it("deduces literals", function()
    eq("int", c.literal_type("42"))
    eq("unsigned long", c.literal_type("42UL"))
    eq("long long", c.literal_type("0x10ll"))
    eq("double", c.literal_type("1.5"))
    eq("float", c.literal_type("1e-3f"))
    eq("const char *", c.literal_type('"hi"'))
    eq("char", c.literal_type("'x'"))
    eq("void *", c.literal_type("NULL"))
  end)
end)

describe("deduce_signature", function()
  it("uses argument names and hover types", function()
    eq(
      "void process(int count, char *buf)",
      proto_for({ "  process(count, buf);" }, 0, 3, { count = "int", buf = "char[64]" })
    )
  end)
  it("handles declarations as return type", function()
    eq("struct point *make(int arg1, double arg2)", proto_for({ "struct point *p = make(3, 2.0);" }, 0, 20))
    eq("int f(void)", proto_for({ "  static const int x = f();" }, 0, 24))
  end)
  it("asks hover for assignment targets", function()
    eq("long f(void)", proto_for({ "  total = f();" }, 0, 10, { total = "long" }))
    eq("int f(void)", proto_for({ "  *out = f();" }, 0, 10, { out = "int *" }))
    eq("float f(void)", proto_for({ "  s->val = f();" }, 0, 12, { val = "float" }))
  end)
  it("deduces expressions", function()
    eq(
      "void f(int *x, int arg2, int arg3, size_t arg4, const char *name, int arg6)",
      proto_for({ "  f(&x, a + 1, a < b, sizeof(x), p->name, !ok);" }, 0, 2, {
        x = "int",
        a = "int",
        name = "const char *",
      })
    )
    eq(
      "void f(unsigned char arg1, int arg2)",
      proto_for({ "f((unsigned char)c, g(1));" }, 0, 0, {
        g = { kind = "function", ret = "int" },
      })
    )
    eq("void f(int arr)", proto_for({ "f(arr[2]);" }, 0, 0, { arr = "int[4]" }))
  end)
  it("leaves placeholders and uses bool for conditions", function()
    eq("TYPE f(TYPE y)", proto_for({ "  x = f(y);" }, 0, 6))
    eq("int f(void)", proto_for({ "  if (f())" }, 0, 6))
    eq("bool f()", proto_for({ "  while (f()) {" }, 0, 9, {}, cpp))
  end)
  it("uses the enclosing return type for return statements", function()
    eq(
      "double f(double v)",
      proto_for({ "static double g(double v) {", "  return f(v);", "}" }, 1, 9, { v = "double" })
    )
  end)
  it("handles multi-line calls", function()
    eq("void f(int a, int b)", proto_for({ "f(a,", "  b);" }, 0, 0, { a = "int", b = "int" }))
  end)
  it("rejects bad cursor positions", function()
    local buf = scratch({ "  obj.f(1);", "x = 1;" })
    eq(nil, (c.parse_call(buf, 0, 6)))
    eq(nil, (c.parse_call(buf, 1, 0)))
  end)
end)

describe("declaration_from_definition", function()
  it("keeps default args and qualification from the old declaration", function()
    local def = cpp.parse_proto("int ns::area(int w, int h)")
    local old = cpp.parse_proto("int area(int w, int h = 1)")
    eq("int area(int w, int h = 1);", cpp.declaration_from_definition(def, old))
  end)
end)

describe("file edits", function()
  it("inserts forward declarations after includes", function()
    local buf = scratch({ "#include <stdio.h>", "", "int main(void) {", "}" })
    c.insert_forward_declaration(buf, "void a(void);")
    c.insert_forward_declaration(buf, "void b(void);")
    eq(
      { "#include <stdio.h>", "", "void a(void);", "void b(void);", "", "int main(void) {", "}" },
      vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    )
  end)
  it("inserts header declarations inside the guard", function()
    local buf = scratch(c.new_header_lines("/tmp/my-lib.h"))
    c.insert_declaration(buf, "int a(void);")
    c.insert_declaration(buf, "int b(void);")
    eq({
      "#ifndef MY_LIB_H",
      "#define MY_LIB_H",
      "",
      "int a(void);",
      "int b(void);",
      "",
      "#endif /* MY_LIB_H */",
    }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
  it("adds includes once", function()
    local buf = scratch({ "#include <stdio.h>", "", "int x;" })
    vim.api.nvim_buf_set_name(buf, "/tmp/ff_test/main.c")
    c.ensure_include(buf, "/tmp/ff_test/main.h")
    c.ensure_include(buf, "/tmp/ff_test/main.h")
    eq({ "#include <stdio.h>", '#include "main.h"', "", "int x;" }, vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  end)
end)
