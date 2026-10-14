-- Zrzut skrótów Omarchy z prawdziwych plików Lua, z atrapą API Hyprlanda (hl).
-- Atrapa tylko zapisuje wywołania hl.bind — nic nie wykonuje.
-- Wyjście (TSV): klawisze, opis, rodzaj, polecenie
local OP = os.getenv("OMARCHY_PATH") or "/usr/share/omarchy"
package.path = OP .. "/?.lua;" .. OP .. "/?/init.lua;" .. package.path

local function proxy(name)
  return setmetatable({}, {
    __index = function(_, k) return proxy(name .. "." .. k) end,
    __call = function(_, ...)
      local a = { ... }
      local parts = {}
      for i = 1, select("#", ...) do
        local v = a[i]
        parts[#parts + 1] = type(v) == "table" and "{…}" or tostring(v)
      end
      return { dsp = name, args = table.concat(parts, ", ") }
    end,
  })
end

local binds = {}
hl = proxy("hl")
rawset(hl, "dsp", proxy("dsp"))
rawset(hl.dsp, "exec_cmd", function(cmd) return { exec = cmd } end)
rawset(hl, "bind", function(keys, d, opts)
  local kind, cmd
  if type(d) == "table" and d.exec then kind, cmd = "exec", d.exec
  elseif type(d) == "table" and d.dsp then kind, cmd = "dsp", d.dsp .. "(" .. (d.args or "") .. ")"
  elseif type(d) == "function" then kind, cmd = "lua", "<funkcja Lua>"
  else kind, cmd = "?", tostring(d) end
  binds[#binds + 1] = { keys, (opts and opts.description) or "", kind, cmd }
end)
for _, f in ipairs({ "unbind", "on", "config", "exec_cmd", "env", "window_rule", "layer_rule", "workspace_rule", "monitor", "device", "gesture", "submap" }) do
  rawset(hl, f, function() end)
end

dofile(OP .. "/default/hypr/helpers.lua")
require("default.hypr.bindings")

for _, b in ipairs(binds) do
  print(table.concat({ b[1], b[2], b[3], (b[4]:gsub("[\t\n]", " ")) }, "\t"))
end
io.stderr:write("bindów: " .. #binds .. "\n")
