return require("effen.lang.c_family").new({
  name = "c",
  header_exts = { "h" },
  source_exts = { "c" },
  default_header_ext = "h",
  bool_type = "int",
  empty_params = "void",
  null_type = "void *",
})
