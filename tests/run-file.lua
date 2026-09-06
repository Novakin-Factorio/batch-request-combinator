-- Fengari can report an uncaught Lua error with exit code zero. Make failures explicit.
local path = table.remove(arg, 1)
local ok, failure = pcall(function() assert(loadfile(path))() end)
if not ok then
  io.stderr:write(tostring(failure) .. "\n")
  os.exit(1)
end
