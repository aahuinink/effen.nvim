return require("effen.lang.c_family").new({
  name = "cpp",
  header_exts = { "hpp", "h", "hh", "hxx", "H" },
  source_exts = { "cpp", "cc", "cxx", "C" },
  default_header_ext = "hpp",
  bool_type = "bool",
  empty_params = "",
  null_type = "void *",
  references = true,
})
