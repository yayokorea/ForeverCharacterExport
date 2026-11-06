std = "lua51"
self = false -- Method receivers may be unused in stateless helpers.
max_line_length = 120
read_globals = {
    "issecretvalue", "canaccessvalue", "Enum", "CreateFrame", "UIParent",
}
globals = { "SLASH_FOREVERCHARACTEREXPORT1", "SlashCmdList" }
exclude_files = { ".tools/**" }
