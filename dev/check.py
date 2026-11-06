"""Local Lua 5.1 syntax, luacheck, and mocked contract tests. Never a WoW runtime test."""
from pathlib import Path
import sys

DEV = Path(__file__).resolve().parent
ADDON = DEV.parent / "addon" / "ForeverCharacterExport"
sys.path.insert(0, str(DEV / ".tools/pylib"))
from lupa.lua51 import LuaRuntime  # noqa: E402

lua = LuaRuntime(unpack_returned_tuples=True)
files = [line.strip() for line in (ADDON / "ForeverCharacterExport.toc").read_text(encoding="utf-8").splitlines()
         if line.strip().endswith(".lua")]
compile_lua = lua.eval("function(src, name) local f, err = loadstring(src, name); assert(f, err); return f end")
for filename in files:
    compile_lua((ADDON / filename).read_text(encoding="utf-8-sig"), "@" + filename)
print(f"Lua 5.1 syntax: {len(files)} TOC files passed")

checker_path = (DEV / ".tools/luacheck-1.2.0/src").as_posix()
lua.globals().checker_path = checker_path
lua.execute('package.path = checker_path .. "/?.lua;" .. checker_path .. "/?/init.lua;" .. package.path')
lint = lua.eval('function(src, opts) return require("luacheck").check_strings({src}, opts) end')
options = lua.table()
options.std = "lua51"
options["self"] = False
options.max_line_length = 120
# Direct globals a file needs are declared in that file: `-- luacheck: read globals Foo` or `-- luacheck: globals Foo`.
options.read_globals = lua.table_from(["issecretvalue", "canaccessvalue", "Enum", "CreateFrame", "UIParent"])
options.globals = lua.table_from(["SlashCmdList", "ForeverCharacterExportDB"])
failed = False
for filename in files:
    result = lint((ADDON / filename).read_text(encoding="utf-8-sig"), options)
    for _, issue in result[1].items():
        print(f'{filename}:{issue.line}:{issue.column}: {issue.code} {issue.name or ""}')
    failed |= result.errors + result.warnings + result.fatals > 0
if failed:
    raise SystemExit("luacheck failed")
print("luacheck 1.2.0: no warnings or errors")

# Mocked tests: prelude, then every TOC file once in order, then core and per-collector test files.
addon = lua.table()
lua.globals().AddonUnderTest = addon
lua.execute((DEV / "tests/prelude.lua").read_text(encoding="utf-8"))
for filename in files:
    compile_lua((ADDON / filename).read_text(encoding="utf-8-sig"), "@" + filename)("ForeverCharacterExport", addon)
test_files = [DEV / "tests/contracts.lua"] + sorted((DEV / "tests/collectors").glob("*.lua"))
for test_file in test_files:
    compile_lua(test_file.read_text(encoding="utf-8-sig"), "@" + test_file.name)()
failures, total = lua.eval("RunAllTests")()
if failures:
    raise SystemExit(f"{failures} of {total} mocked tests failed")
print(f"Mock contract tests passed: {total} (not in-game verification)")
