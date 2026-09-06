for index = 1, #arg do
  local chunk, failure = loadfile(arg[index])
  assert(chunk, failure)
end

print("Lua syntax check passed (" .. tostring(#arg) .. " files)")
