# preferencesProbe.jl — explicit preferences become a user-editable file.
#
# Run: julia --startup-file=no --project=. test/preferencesProbe.jl
using Flooty

failures = String[]
function check(name::String, ok::Bool, detail = "")
    shown = detail === "" || detail === nothing ? "" : string(detail)
    println(ok ? "PASS  " : "FAIL  ", name, isempty(shown) ? "" : "  [" * shown * "]")
    ok || push!(failures, name)
end

path = joinpath(mktempdir(), "preferences.md")
ENV["FLOOTY_PREFERENCES_PATH"] = path
project = preferenceProjectName()

check("a global preference is written",
      recordUserPreference!("global", "Always use tabs"; source = "test"))
check("…and a project preference is written",
      recordUserPreference!("project", "Run tests after changes"; source = "test"))
txt = read(path, String)
check("…in editable markdown sections",
      occursin("## Global", txt) && occursin("## Project: " * project, txt), txt)
check("…with dedupe", !recordUserPreference!("global", "always use tabs"),
      read(path, String))
check("…and a prompt-ready context",
      occursin("Always use tabs", preferencesContext()) &&
      occursin("Run tests after changes", preferencesContext()), preferencesContext())

root = ensureRootChatSession!()
PREFERENCE_COMPLETE[] = _ ->
    "{\"preferences\":[{\"scope\":\"project\",\"text\":\"Prefer concise answers\"}]}"
check("an explicit preference message is accepted",
      noteUserMessage!(root, "Please remember I prefer concise answers"))
for _ in 1:40
    occursin("Prefer concise answers", read(path, String)) && break
    sleep(0.1)
end
check("…and the model-extracted preference reaches the file",
      occursin("Prefer concise answers", read(path, String)), read(path, String))

rm(path; force = true)
println()
if isempty(failures)
    println("PREFERENCES_PROBE_OK")
else
    println("FAILED CHECKS: ", join(failures, ", ")); exit(1)
end
