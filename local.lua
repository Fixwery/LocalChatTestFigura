
local CFG = {
  hookChat     = true,
  syncPing     = true,
  maxBubbles   = 1,
  maxWords     = 40,
  maxChars     = 200,
  -- per-tier ceilings (further clamped by the viewer's real permissions)
  -- merge = a message with MORE words than this turns into one billboard
  tierLimits   = {
    [1] = { chars = 48,  words = 10, bubbles = 1, merge = 4  }, -- DEFAULT / LOW
    [2] = { chars = 96,  words = 20, bubbles = 3, merge = 8  }, -- NORMAL
    [3] = { chars = 160, words = 32, bubbles = 3, merge = 14 }, -- HIGH / MAX
  },
  maxWidth     = 110,
  lineHeight   = 9,      -- keep 9 (vanilla font) so merged text lines up with the words
  padding      = { x = 6, y = 4 },
  scale        = 0.45,
  offset       = vec(0, 2.45, 0),
  stackGap     = 0.08,
  cullDistance = 48,
  fullBright   = true,
  hideInFirstPerson = true, -- hide your own bubbles while in first person

  silent = {
    prefix       = "~",
    command      = "/bubble",
    alwaysSilent = true,
    toggleKey    = "key.keyboard.right.alt",
    notify       = true,
  },

  lookAtCamera = true,
  faceOffset   = 180,
  mirrorX      = true,
  fullBillboard= true,
  pitchSign    = 1,
  layerGap     = 0.02,

  background = { enabled = false, color = vec(0, 0, 0, 0.35) },

  text = {
    bold = false, italic = false, underlined = false,
    strikethrough = false, obfuscated = false,
    font = nil, shadow = false,
    outline = true, outlineColor = "#2d2b2d",
  },

  -- wobble applied to every WORD (and the icon) when it spawns
  appear = {
    speed = 16, wobble = 34, wobble2 = 61, burst = 100,
    stretch = 2.2, overshoot = 1.1, bounce = 2.5,
    settle = 0.5,
  },
  idle = { amplitude = 1.4, speed = 2.4 },   -- whole-bubble bob
  fade = { time = 0.6, squash = 0.88, widen = 0.38, wobble = 0.09, opacity = true },
  hold = { base = 2.4, perChar = 0.045 },

  -- flash when a long message collapses into one billboard
  merge = { flashTime = 0.18, punch = 0.15 },

  perf = { auto = true, forceTier = 0, budgetUse = 0.65, skipUpdates = true },

  typing = {
    wordDelay = 0.10,    -- seconds between words
    perChar   = 0.012,   -- extra delay per letter of the previous word
    pauses = {
      [","] = 0.14, ["."] = 0.30, ["!"] = 0.30, ["?"] = 0.30,
      [";"] = 0.20, [":"] = 0.20, ["-"] = 0.10, ["…"] = 0.35,
    },
  },

  textColor = "#ffffff",
  -- gradient is spread ACROSS the words (first word = first colour)
  gradient = { enabled = true, colors = { "#ffffff", "#3e3e3e" } },

  -- per-word options: color, rainbow, scale, shake/wave (stronger spawn wobble),
  -- bold / italic / underlined / strikethrough / obfuscated, font
  words = {
    hello = { color = "#ff3b3b", shake = 0.8 },
    hi    = { color = "#ff3b3b", shake = 0.8 },
    wow   = { rainbow = true, wave = 1.2 },
    love  = { color = "#ff7ac8", wave = 1.0 },
    help  = { color = "#ffd43b", shake = 1.4 },
    cool  = { color = "#4dd2ff", wave = 0.8 },
  },

  sound = {
    enabled = true,
    mode    = "all",   -- "single" | "alternate" | "random" | "all"
    everyN  = 1,       -- play on every Nth WORD
    volume  = 0.25,
    voices = {
      { id = "minecraft:entity.skeleton.hurt",    pitch = { 0.9, 1.1 } },
      { id = "minecraft:entity.skeleton.ambient", pitch = { 1.3, 1.6 } },
    },
  },

  image = {
    enabled = false,
    texture = "Icon",          -- avatar texture name, or "" for built-in
    speakTexture = "Speak",    -- shown while words are spawning; "" built-in, false = none
    size = 10, width = nil, height = nil,
    -- setLight(15,15) removes world shading, but it cannot brighten dark
    -- pixels in the avatar texture. >1 scales icon RGB once at load time.
    brightness = 3.0,
    pos = "left", spacing = 5,
    animate = true, delay = 0,
  },

  follow = {
    enabled = false,
    part    = function() return models.model.Head end,
    offset  = vec(0, 0.7, 0),
    speed   = 8,
  },
}

------------------------------------------------------------------
-- INTERNALS
------------------------------------------------------------------
ChatBubble = { config = CFG, silentMode = CFG.silent.alwaysSilent }

local floor, ceil, sin, cos, exp, max, min = math.floor, math.ceil, math.sin, math.cos, math.exp, math.max, math.min
local CHAR = "[%z\1-\127\194-\244][\128-\191]*"
local EMPTY = {}

local root     = models:newPart("ChatBubbleRoot", "World")
local pixel    = textures:newTexture("chatbubble_px", 1, 1):setPixel(0, 0, vec(1, 1, 1, 1)):update()
local bubbles  = {}
local anchor   = nil
local lastTime = client.getSystemTime() / 1000
local idCounter, voiceIdx = 0, 0
local IS_HOST = false
do local ok, h = pcall(function() return host:isHost() end); IS_HOST = ok and h == true end

-- permission tier ------------------------------------------------
local TIER = 1
local maxRender, maxCx = 0, 0
pcall(function() maxRender = avatar:getMaxRenderCount() or 0 end)
pcall(function() maxCx = avatar:getMaxComplexity() or 0 end)
if maxRender <= 0 then
  local ok, lvl = pcall(function() return avatar:getPermissionLevel() end)
  if ok and lvl then
    lvl = tostring(lvl):upper()
    if lvl:find("MAX") or lvl:find("HIGH") then maxRender = 32768
    elseif lvl:find("NORMAL") or lvl:find("MEDIUM") then maxRender = 8192 end
  end
end
if CFG.perf.auto then
  if maxRender >= 32768 then TIER = 3 elseif maxRender >= 8192 then TIER = 2 else TIER = 1 end
else
  TIER = CFG.perf.forceTier or 1
end
TIER = max(1, min(3, TIER))

local HAS_INSTR = pcall(function() return avatar:getCurrentInstructions() end)
local renderBudget = maxRender > 0 and maxRender * CFG.perf.budgetUse or math.huge
local function hot() return HAS_INSTR and avatar:getCurrentInstructions() > renderBudget end

local HAS_FIRSTPERSON = pcall(function() return renderer:isFirstPerson() end)

local function clamp01(v) return v < 0 and 0 or (v > 1 and 1 or v) end
local function X(lx) return CFG.mirrorX and -lx or lx end

-- utf8 helpers ---------------------------------------------------
local function utf8len(s) return (select(2, s:gsub("[^\128-\191]", ""))) end
-- cap to n BYTES without cutting a multibyte character
local function utf8cap(s, n)
  if #s <= n then return s end
  local i = n
  while i > 0 do
    local c = s:byte(i + 1)
    if c and c >= 128 and c < 192 then i = i - 1 else break end
  end
  return s:sub(1, i)
end

local function budgetCharCap(bubbleCap)
  local n = max(bubbleCap, 1)
  if maxCx > 0 then return floor(maxCx * 0.45 / 2 / n) end
  if maxRender > 0 then return floor(maxRender * 0.03 / n) end
  return math.huge
end

------------------------------------------------------------------
-- TEXTURES / ICONS
------------------------------------------------------------------
local builtins, iconCache, iconOverride, speakOverride = {}, {}, nil, nil
local brightCache, brightIdx = {}, 0

local function findTexture(name)
  if type(name) ~= "string" or name == "" then return nil end
  local ok, t = pcall(function() return textures:get(name) end)
  if ok and t then return t end
  ok, t = pcall(function() return textures[name] end)
  if ok and t then return t end
  -- tolerant lookup (case / ".png" / "model.Name"), done once per name
  local want = name:lower():gsub("%.png$", "")
  local ok2, list = pcall(function() return textures:getTextures() end)
  if ok2 and list then
    for _, tx in pairs(list) do
      local okn, n = pcall(function() return tx:getName() end)
      if okn and type(n) == "string" then
        n = n:lower():gsub("%.png$", "")
        if n == want or n:sub(-#want - 1) == "." .. want then return tx end
      end
    end
  end
  return nil
end

local function rect(t, x, y, w, h, col)
  local ok = pcall(function() t:fill(x, y, w, h, col) end)
  if not ok then
    for yy = y, y + h - 1 do for xx = x, x + w - 1 do t:setPixel(xx, yy, col) end end
  end
end

-- built-in 16x16 icon, drawn with a few fill() calls (cheap)
local function builtInIcon(speaking)
  local key = speaking and "speak" or "idle"
  if builtins[key] then return builtins[key] end
  local name = speaking and "chatbubble_auto_speak_icon" or "chatbubble_auto_icon"
  local ok, tex = pcall(function()
    local t = textures:get(name)
    if t then return t end
    t = textures:newTexture(name, 16, 16)
    local white, dark = vec(1, 1, 1, 1), vec(0.18, 0.17, 0.18, 1)
    rect(t, 1, 1, 14, 11, white)
    for k = 0, 3 do rect(t, 3 + k, 9 + k, 6 - 2 * k, 1, white) end
    if speaking then
      rect(t, 6, 3, 4, 7, dark); rect(t, 5, 4, 6, 5, dark)
    else
      rect(t, 5, 6, 1, 1, dark); rect(t, 8, 6, 1, 1, dark); rect(t, 11, 6, 1, 1, dark)
    end
    t:update()
    return t
  end)
  if ok then builtins[key] = tex end
  return builtins[key]
end

-- Brighten a CUSTOM icon texture once and cache it. The built-in icon is
-- already white, so only real avatar textures are touched here.
local function brightIconTexture(tex, factor)
  if not tex or not factor or factor <= 1 then return tex end
  local okName, name = pcall(function() return tex:getName() end)
  if not okName or type(name) ~= "string" or name == "" then name = "tex" end
  local okDim, d = pcall(function() return tex:getDimensions() end)
  if not okDim or not d then return tex end
  local w, h = tonumber(d.x) or 0, tonumber(d.y) or 0
  if w <= 0 or h <= 0 then return tex end

  local ck = name .. "|" .. w .. "x" .. h .. "|" .. tostring(factor)
  if brightCache[ck] then return brightCache[ck] end

  local ok, out = pcall(function()
    brightIdx = brightIdx + 1
    local t = textures:copy("chatbubble_bright_" .. brightIdx, tex)
    t:applyFunc(0, 0, w, h, function(c)
      return vec(min(1, c.x * factor), min(1, c.y * factor), min(1, c.z * factor), c.w)
    end):update()
    return t
  end)
  if ok and out then brightCache[ck] = out; return out end
  return tex
end

local function resolveIcon(name, sizeOpt, widthOpt, heightOpt, speaking)
  local ck = table.concat({ tostring(name), tostring(speaking), tostring(sizeOpt),
                            tostring(widthOpt), tostring(heightOpt), tostring(CFG.image.brightness) }, "|")
  if iconCache[ck] then return iconCache[ck] end
  local custom = findTexture(name)
  local tex = custom or builtInIcon(speaking)
  if not tex then return nil end
  if custom then tex = brightIconTexture(tex, CFG.image.brightness) end
  local tw, th = 16, 16
  local ok, d = pcall(function() return tex:getDimensions() end)
  if ok and d then
    local w, h = tonumber(d.x), tonumber(d.y)
    if w and h and w > 0 and h > 0 then tw, th = w, h end
  end
  local iw, ih = tw, th
  local s = tonumber(sizeOpt)
  if s and s > 0 then
    local k = s / max(tw, th); iw, ih = tw * k, th * k
  else
    local w, h = tonumber(widthOpt), tonumber(heightOpt)
    if w and w > 0 then iw, ih = w, w * th / tw
    elseif h and h > 0 then iw, ih = h * tw / th, h end
  end
  local r = { tex = tex, tw = tw, th = th, w = iw, h = ih }
  iconCache[ck] = r
  return r
end

------------------------------------------------------------------
-- COLOURS / STYLE
------------------------------------------------------------------
local function hexVec(h) return vectors.hexToRGB(h) end
local gradVecs = {}
for i, c in ipairs(CFG.gradient.colors) do gradVecs[i] = hexVec(c) end
local baseColor = hexVec(CFG.textColor)

local function gradientHex(t)
  local n = #gradVecs
  local col
  if n == 1 then col = gradVecs[1]
  else
    local s = clamp01(t) * (n - 1)
    local i = min(floor(s), n - 2)
    col = gradVecs[i + 1] + (gradVecs[i + 2] - gradVecs[i + 1]) * (s - i)
  end
  return "#" .. vectors.rgbToHex(col)
end

local function pick(a, b, c)
  if a ~= nil then return a end
  if b ~= nil then return b end
  return c
end

local function styled(text, color, st)
  return {
    text = text, color = color,
    bold = st.bold, italic = st.italic, underlined = st.underlined,
    strikethrough = st.strikethrough, obfuscated = st.obfuscated, font = st.font,
  }
end

-- JSON for one word (static; rainbow = one coloured component per letter)
local function wordJson(w, white)
  if white then return styled(w.raw, "#ffffff", w.st) end
  if w.rainbow then
    local arr, i = { "" }, 0
    for c in w.raw:gmatch(CHAR) do
      i = i + 1
      arr[#arr + 1] = styled(c, "#" .. vectors.rgbToHex(vectors.hsvToRGB((i * 0.13) % 1, 0.85, 1)), w.st)
    end
    return arr
  end
  return styled(w.raw, w.color, w.st)
end

-- JSON for the WHOLE message (used for the merged billboard)
local function mergedJson(b, white)
  local arr = { "" }
  for li, line in ipairs(b.lines) do
    for k, w in ipairs(line.words) do
      local prefix = (k == 1 and li > 1) and "\n" or (k > 1 and " " or "")
      if prefix ~= "" then arr[#arr + 1] = { text = prefix } end
      arr[#arr + 1] = wordJson(w, white)
    end
  end
  return toJson(arr)
end

-- easing ----------------------------------------------------------
local function easeInOutCubic(t)
  return t < 0.5 and 4 * t * t * t or 1 - ((-2 * t + 2) ^ 3) * 0.5
end
local function easeOutBack(t, amount)
  local c1 = 1.70158 * (amount or 1)
  local c3, u = c1 + 1, t - 1
  return 1 + c3 * u * u * u + c1 * u * u
end

-- spawn wobble shared by words and icon: returns scaleX, scaleY, hopY
local A = CFG.appear
local settle = max(A.settle, 0.05)
local function pop(ct, energy)
  local back = easeOutBack(clamp01(ct / settle), A.overshoot)
  local decay = exp(-A.speed * ct)
  local burst = exp(-A.burst * ct)
  local wob = 0.6 * cos(A.wobble * ct) + 0.4 * cos(A.wobble2 * ct)
  local k = A.stretch * energy * decay
  local csx = back + k * (wob + 0.5 * burst * sin(A.wobble * ct))
  local csy = back + k * (0.9 * cos(A.wobble * ct - 1.9) + 0.7 * burst)
  return max(0.08, csx), max(0.08, csy), A.bounce * decay * sin(A.wobble2 * ct)
end

-- sound -----------------------------------------------------------
local function validPos(pos)
  if pos == nil then return false end
  local ok, x, y, z = pcall(function() return pos.x, pos.y, pos.z end)
  if not ok or type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" then return false end
  return x == x and y == y and z == z
end

local function playVoice(x, y, z)
  local S = CFG.sound
  if not S.enabled or #S.voices == 0 then return end
  local pos = vec(x, y, z)
  if not validPos(pos) then return end
  local list
  if S.mode == "single" then list = { S.voices[1] }
  elseif S.mode == "all" then list = S.voices
  elseif S.mode == "random" then list = { S.voices[math.random(#S.voices)] }
  else voiceIdx = voiceIdx % #S.voices + 1; list = { S.voices[voiceIdx] } end
  for _, v in ipairs(list) do
    local p = v.pitch or { 1, 1 }
    pcall(sounds.playSound, sounds, v.id, pos, S.volume, p[1] + (p[2] - p[1]) * math.random())
  end
end

------------------------------------------------------------------
-- TASK BUILDERS
------------------------------------------------------------------
local function newText(b, name)
  local T = CFG.text
  local tk = b.part:newText(name)
  tk:setShadow(T.shadow):setBackground(false):setAlignment("CENTER")
  if T.outline then tk:setOutline(true):setOutlineColor(hexVec(T.outlineColor)) end
  if CFG.fullBright then tk:setLight(15, 15) end
  return tk
end

local function newSprite(b, name, ic, x, y, z)
  local sp = b.part:newSprite(name)
  sp:setTexture(ic.tex, ic.tw, ic.th):setSize(ic.w, ic.h):setPos(x, y, z)
    :setColor(vec(1, 1, 1, 1)):setRenderType("TRANSLUCENT")
  if CFG.fullBright then sp:setLight(15, 15) end
  sp:setVisible(false)
  return sp
end

local function addWord(b, w, animate)
  local tk = newText(b, "w" .. w.i)
  tk:setText(toJson(wordJson(w, false))):setPos(w.x, w.fy, b.textZ):setScale(w.scale, w.scale, 1)
  w.task, w.born = tk, b.age
  if animate then
    local csx, csy, oy = pop(0, w.energy)
    local sy = csy * w.scale
    tk:setPos(w.x, w.y - CFG.lineHeight * 0.5 * (1 - sy) + oy, b.textZ):setScale(csx * w.scale, sy, 1)
  end
end

local function animateWord(b, w)
  local csx, csy, oy = pop(b.age - w.born, w.energy)
  local sy = csy * w.scale
  w.task:setPos(w.x, w.y - CFG.lineHeight * 0.5 * (1 - sy) + oy, b.textZ)
        :setScale(csx * w.scale, sy, 1)
end

-- Replace every word task with ONE billboard.
local function mergeBubble(b, flash)
  if b.merged then return end
  b.merged = true
  for _, w in ipairs(b.words) do
    if w.task then b.part:removeTask("w" .. w.i); w.task = nil end
  end
  local tk = newText(b, "text")
  tk:setPos(b.textX, b.textY, b.textZ):setScale(1, 1, 1)
  if flash and CFG.merge.flashTime > 0 then
    tk:setText(mergedJson(b, true))
    b.flashStart = b.age
  else
    tk:setText(mergedJson(b, false))
  end
  b.textTask = tk
end

------------------------------------------------------------------
-- SPAWN
------------------------------------------------------------------
local function spawn(text, opts)
  opts = opts or {}

  local lim = CFG.tierLimits[TIER] or EMPTY
  local bubbleCap = min(lim.bubbles or CFG.maxBubbles, CFG.maxBubbles)
  local charCap = min(lim.chars or CFG.maxChars, CFG.maxChars, budgetCharCap(bubbleCap))
  if hot() then charCap = floor(charCap * 0.6) end
  charCap = max(charCap, 1)
  local wordCap = min(lim.words or CFG.maxWords, CFG.maxWords, max(1, floor(charCap / 3)))

  -- split into words, respecting the caps -------------------------
  local words, total = {}, 0
  for raw in text:gmatch("%S+") do
    if #words >= wordCap then break end
    local room = charCap - total - (#words > 0 and 1 or 0)
    if room <= 0 then break end
    if utf8len(raw) > room then raw = utf8cap(raw, room) end
    if raw == "" then break end
    local len = utf8len(raw)
    words[#words + 1] = { raw = raw, len = len }
    total = total + len + (#words > 1 and 1 or 0)
  end
  if #words == 0 then return end

  if #bubbles == 0 then lastTime = client.getSystemTime() / 1000 end
  idCounter = idCounter + 1
  local b = {
    id = idCounter, age = 0, stackY = 0, vis = false,
    fading = false, fadeStart = 0, fadeOpacity = 1,
    words = words, shown = 0, settled = 0, merged = false,
    pauses = {}, pauseIdx = 1, useSpeak = false, total = total,
  }
  b.part = root:newPart("b" .. b.id)
  b.part:setVisible(false) -- the update loop positions it first, then shows it

  -- layout --------------------------------------------------------
  local LH = CFG.lineHeight
  local spaceW = client.getTextWidth(" ")
  local lines, line = {}, { w = 0, n = 0, words = {} }
  for i, w in ipairs(words) do
    w.i = i
    w.w = client.getTextWidth(w.raw)
    if line.n > 0 and line.w + spaceW + w.w > CFG.maxWidth then
      lines[#lines + 1] = line
      line = { w = 0, n = 0, words = {} }
    end
    w.line = #lines + 1
    w.off = line.n > 0 and (line.w + spaceW) or 0
    line.w = w.off + w.w
    line.n = line.n + 1
    line.words[line.n] = w
  end
  lines[#lines + 1] = line
  b.lines = lines
  local textW = 1
  for _, l in ipairs(lines) do textW = max(textW, l.w) end
  local textH = #lines * LH

  -- per-word style / colour ---------------------------------------
  local T, n = CFG.text, #words
  for i, w in ipairs(words) do
    local key = (w.raw:lower():gsub("%p", ""))
    local fx = CFG.words[key] or EMPTY
    w.st = {
      bold = pick(fx.bold, opts.bold, T.bold), italic = pick(fx.italic, opts.italic, T.italic),
      underlined = pick(fx.underlined, opts.underlined, T.underlined),
      strikethrough = pick(fx.strikethrough, opts.strikethrough, T.strikethrough),
      obfuscated = pick(fx.obfuscated, opts.obfuscated, T.obfuscated),
      font = fx.font or opts.font or T.font,
    }
    local c = fx.color or opts.color
    if not c then
      if CFG.gradient.enabled then c = gradientHex(n > 1 and (i - 1) / (n - 1) or 0)
      else c = "#" .. vectors.rgbToHex(baseColor) end
    end
    w.color, w.rainbow = c, fx.rainbow
    w.scale = fx.scale or 1
    w.energy = 1 + 0.5 * ((fx.shake or 0) + (fx.wave or 0))
  end

  -- timeline (one entry per WORD, punctuation pauses) -------------
  local t, TY = 0, CFG.typing
  for _, w in ipairs(words) do
    w.t = t
    t = t + TY.wordDelay + TY.perChar * w.len
    local pz = TY.pauses[w.raw:match(CHAR .. "$") or ""]
    if pz and pz > 0 then b.pauses[#b.pauses + 1] = { t, t + pz }; t = t + pz end
  end
  b.typeEnd = t
  b.life = t + CFG.hold.base + CFG.hold.perChar * total
  b.long = n > (lim.merge or 6)
  if b.long then
    b.mergeAt = t + settle + 0.05
    b.life = max(b.life, b.mergeAt + 0.6)
  end

  -- icon ----------------------------------------------------------
  local I = CFG.image
  local useImage = opts.image
  if useImage == nil then
    if iconOverride == false then useImage = false
    else useImage = I.enabled or iconOverride ~= nil end
  end
  local icon, speakIcon
  if useImage ~= false then
    local imgName = type(useImage) == "string" and useImage or (iconOverride or I.texture)
    icon = resolveIcon(imgName, opts.imageSize or I.size, opts.imageWidth or I.width, opts.imageHeight or I.height)
  end
  if icon then
    local sn = opts.imageSpeaking
    if sn == nil then sn = speakOverride end
    if sn == nil then sn = I.speakTexture end
    if sn ~= nil and sn ~= false then
      if type(sn) ~= "string" then sn = "" end
      speakIcon = resolveIcon(sn, opts.imageSize or I.size, opts.imageWidth or I.width,
                              opts.imageHeight or I.height, true)
    end
  end

  local ipos = opts.imagePos or I.pos
  local iw, ih = icon and icon.w or 0, icon and icon.h or 0
  local G, px, py = I.spacing, CFG.padding.x, CFG.padding.y
  local W, H, textCX, textTop, imgLeft, imgTop

  if icon and (ipos == "left" or ipos == "right") then
    W, H = textW + iw + G + px * 2, max(textH, ih) + py * 2
    textTop = H / 2 + textH / 2
    if ipos == "right" then
      textCX = -W / 2 + px + textW / 2;  imgLeft = W / 2 - px - iw
    else
      textCX = W / 2 - px - textW / 2;   imgLeft = -W / 2 + px
    end
    imgTop = H / 2 + ih / 2
  elseif icon then
    W, H = max(textW, iw) + px * 2, textH + ih + G + py * 2
    textCX, imgLeft = 0, -iw / 2
    if ipos == "top" then imgTop = H - py; textTop = H - py - ih - G
    else textTop = H - py; imgTop = H - py - textH - G end
  else
    W, H = textW + px * 2, textH + py * 2
    textCX, textTop = 0, H - py
  end
  b.W, b.H = W, H

  -- text is CENTER aligned, so its anchor is the CENTER of the text block
  -- (the old code used the left edge here, which pushed the text sideways)
  local gap = CFG.layerGap
  b.textX, b.textY, b.textZ = X(textCX), textTop, -gap * 2
  for _, w in ipairs(words) do
    w.x = X(textCX - lines[w.line].w / 2 + w.off + w.w / 2)
    w.y = textTop - (w.line - 1) * LH
    w.fy = w.y - LH * 0.5 * (1 - w.scale)
  end

  -- background / icon tasks ----------------------------------------
  if CFG.background.enabled then
    local bg = b.part:newSprite("bg")
    bg:setTexture(pixel, 1, 1):setSize(W, H):setColor(CFG.background.color)
      :setRenderType("TRANSLUCENT"):setPos(X(-W / 2), H, gap)
    if CFG.fullBright then bg:setLight(15, 15) end
    b.bg, b.bgColor = bg, CFG.background.color
  end

  if icon then
    -- TWO sprites (idle + speaking) that are just toggled. Swapping the
    -- texture of one sprite is what produced the "missing texture" icon.
    local ia = {
      left = imgLeft, top = imgTop, w = iw, h = ih, z = -gap,
      idle = newSprite(b, "img", icon, X(imgLeft), imgTop, -gap),
      revealed = false, done = not I.animate, csx = 1, csy = 1, born = 0,
    }
    if speakIcon then
      ia.speak = newSprite(b, "imgSpeak", speakIcon, X(imgLeft), imgTop, -gap)
    end
    ia.active = ia.idle
    b.icon = ia
  end

  -- bubble limit ----------------------------------------------------
  table.insert(bubbles, 1, b)
  if TIER == 1 then
    for i = #bubbles, bubbleCap + 1, -1 do
      bubbles[i].part:remove(); table.remove(bubbles, i)
    end
  else
    for i = bubbleCap + 1, #bubbles do
      local o = bubbles[i]
      if not o.fading then o.fading = true; o.fadeStart = o.age end
    end
  end
  return b
end

------------------------------------------------------------------
-- PUBLIC API
------------------------------------------------------------------
function pings.chatBubbleSay(text) spawn(text) end

function ChatBubble.say(text, opts)
  if not text or text == "" then return end
  if CFG.syncPing and IS_HOST and not opts then
    pcall(function() pings.chatBubbleSay(text) end)
  else
    spawn(text, opts)
  end
end

function ChatBubble.clear()
  for i = #bubbles, 1, -1 do bubbles[i].part:remove(); bubbles[i] = nil end
end

function ChatBubble.setIcon(name)
  if name == false then iconOverride = false
  elseif type(name) == "string" and name ~= "" then iconOverride = name
  else iconOverride = "" end
end

function ChatBubble.setSpeakIcon(name)
  if name == false then speakOverride = false
  elseif type(name) == "string" and name ~= "" then speakOverride = name
  else speakOverride = "" end
end

function ChatBubble.setSilent(state)
  ChatBubble.silentMode = state and true or false
  if CFG.silent.notify and IS_HOST then
    pcall(function()
      host:setActionbar(ChatBubble.silentMode and "Chat bubbles: SILENT (not sent to chat)"
                                               or "Chat bubbles: normal chat")
    end)
  end
end

------------------------------------------------------------------
-- CHAT HOOK
------------------------------------------------------------------
local function trim(s) return (s:gsub("^%s+", ""):gsub("%s+$", "")) end

if CFG.hookChat then
  events.CHAT_SEND_MESSAGE:register(function(msg)
    if not msg or msg == "" then return msg end
    local S = CFG.silent
    if S.command ~= "" and (msg == S.command or msg:sub(1, #S.command + 1) == S.command .. " ") then
      ChatBubble.say(trim(msg:sub(#S.command + 1)))
      return nil
    end
    if msg:sub(1, 1) == "/" then return msg end
    if S.prefix ~= "" and msg:sub(1, #S.prefix) == S.prefix then
      ChatBubble.say(trim(msg:sub(#S.prefix + 1)))
      return nil
    end
    if ChatBubble.silentMode then ChatBubble.say(msg); return nil end
    ChatBubble.say(msg)
    return msg
  end)
end

if CFG.silent.toggleKey ~= "" then
  pcall(function()
    local kb = keybinds:newKeybind("Toggle silent bubbles", CFG.silent.toggleKey)
    kb.press = function() ChatBubble.setSilent(not ChatBubble.silentMode); return true end
  end)
end

------------------------------------------------------------------
-- UPDATE LOOP (events.RENDER only)
------------------------------------------------------------------
local lastFrameMS = -1
local F = CFG.fade

local function applyIcon(ia, sp, csx, csy, oy)
  sp:setPos(X(ia.left + ia.w * (1 - csx) * 0.5), ia.top - ia.h * (1 - csy) * 0.5 + oy, ia.z)
    :setSize(ia.w * csx, ia.h * csy)
end

local function setVis(b, v)
  if b.vis ~= v then b.vis = v; b.part:setVisible(v) end
end

local function update(delta)
  if #bubbles == 0 then return end

  local ms = client.getSystemTime()
  if ms == lastFrameMS then return end
  lastFrameMS = ms
  local now = ms / 1000
  local dt = min(now - lastTime, 0.1); lastTime = now

  if not player:isLoaded() then return end
  local pp = player:getPos(delta)

  if CFG.follow.enabled then
    local ok, p = pcall(function() return CFG.follow.part():partToWorldMatrix():apply(0, 0, 0) end)
    local target = (ok and validPos(p)) and (p + CFG.follow.offset) or (pp + CFG.offset)
    anchor = anchor and (anchor + (target - anchor) * (1 - exp(-CFG.follow.speed * dt))) or target
  else
    anchor = pp + CFG.offset
  end

  local cam = client:getCameraPos()
  local ax, ay, az = anchor.x, anchor.y, anchor.z
  local hide = CFG.hideInFirstPerson and IS_HOST and HAS_FIRSTPERSON and renderer:isFirstPerson()
  local S = CFG.scale
  local I = CFG.image
  local stack = 0
  local i = 1

  while i <= #bubbles do
    local b = bubbles[i]
    b.age = b.age + dt

    if not b.fading and b.age > b.life then
      b.fading, b.fadeStart = true, b.age
      mergeBubble(b, false) -- one cheap task for the fade-out
    end

    local sx, sy = 1, 1
    local removed = false
    if b.fading then
      local f = clamp01((b.age - b.fadeStart) / F.time)
      if f >= 1 then
        removed = true
      else
        local p = easeInOutCubic(f)
        sy = max(0.02, 1 - F.squash * p + F.wobble * sin(f * 22) * (1 - f))
        sx = 1 + F.widen * sin(math.pi * p)
        b.fadeOpacity = F.opacity and (1 - p) or 1
      end
    end

    if removed then
      b.part:remove(); table.remove(bubbles, i)
    else
      b.stackY = b.stackY + (stack - b.stackY) * (1 - exp(-10 * dt))
      local bx, by, bz = ax, ay + b.stackY, az
      local dx, dy, dz = cam.x - bx, cam.y - by, cam.z - bz
      local dist2 = dx * dx + dy * dy + dz * dz
      local quiet = CFG.perf.skipUpdates and dist2 > CFG.cullDistance * CFG.cullDistance
      stack = stack + b.H * S / 16 * sy + CFG.stackGap

      if hide or quiet then
        setVis(b, false)
      else
        setVis(b, true)
        local animate = not hot()

        -- placement: face camera + whole-bubble idle bob (ONE setPos) ----
        local yaw, pitch = 0, 0
        if CFG.lookAtCamera then
          yaw = math.deg(math.atan2(dx, dz))
          if CFG.fullBillboard then
            pitch = CFG.pitchSign * math.deg(math.atan2(dy, (dx * dx + dz * dz) ^ 0.5))
          end
        end
        local bob = animate and sin(now * CFG.idle.speed + b.id) * CFG.idle.amplitude * S or 0
        b.part:setPos(bx * 16, by * 16 + bob, bz * 16)
              :setRot(pitch, CFG.faceOffset + yaw, 0)
              :setScale(sx * S, sy * S, S)

        -- words spawn one by one --------------------------------------
        if not b.merged then
          local ws, made = b.words, 0
          while b.shown < #ws and made < 2 and b.age >= ws[b.shown + 1].t do
            b.shown = b.shown + 1; made = made + 1
            local w = ws[b.shown]
            addWord(b, w, animate)
            if b.shown % max(CFG.sound.everyN, 1) == 0 then playVoice(bx, by, bz) end
          end
          -- finish words whose wobble is over (static from now on)
          while b.settled < b.shown and b.age - ws[b.settled + 1].born >= settle do
            b.settled = b.settled + 1
            local w = ws[b.settled]
            w.task:setPos(w.x, w.fy, b.textZ):setScale(w.scale, w.scale, 1)
          end
          if animate then
            for k = b.settled + 1, b.shown do animateWord(b, ws[k]) end
          end
          -- long message: flash + collapse into ONE billboard
          if b.long and b.shown == #ws and b.settled == #ws and b.age >= b.mergeAt then
            mergeBubble(b, true)
          end
        elseif b.flashStart then
          -- flash: white + a little punch, then the real colours (one setText)
          local ft = b.age - b.flashStart
          if ft < CFG.merge.flashTime then
            if animate then
              local s = 1 + CFG.merge.punch * (1 - ft / CFG.merge.flashTime)
              b.textTask:setPos(b.textX, b.textY - (b.H > 0 and CFG.lineHeight * #b.lines * 0.5 * (1 - s) or 0), b.textZ)
                        :setScale(s, s, 1)
            end
          else
            b.flashStart = nil
            b.textTask:setText(mergedJson(b, false))
                      :setPos(b.textX, b.textY, b.textZ):setScale(1, 1, 1)
          end
        end

        -- icon ---------------------------------------------------------
        local ia = b.icon
        if ia then
          if not ia.revealed and b.age >= (I.delay or 0) then
            ia.revealed, ia.born = true, b.age
            ia.active:setVisible(true)
          end
          if ia.revealed then
            if ia.speak then
              local pz = b.pauses
              while pz[b.pauseIdx] and b.age >= pz[b.pauseIdx][2] do b.pauseIdx = b.pauseIdx + 1 end
              local speaking = b.age < b.typeEnd
                and not (pz[b.pauseIdx] and b.age >= pz[b.pauseIdx][1])
              if speaking ~= b.useSpeak then
                b.useSpeak = speaking
                local nxt = speaking and ia.speak or ia.idle
                if nxt ~= ia.active then
                  ia.active:setVisible(false)
                  ia.active = nxt
                  applyIcon(ia, nxt, ia.csx, ia.csy, 0)
                  nxt:setVisible(true)
                end
              end
            end
            if not ia.done and animate then
              local ct = b.age - ia.born
              if ct < settle then
                local csx, csy, oy = pop(ct, 1)
                ia.csx, ia.csy = csx, csy
                applyIcon(ia, ia.active, csx, csy, oy)
              else
                ia.done, ia.csx, ia.csy = true, 1, 1
                applyIcon(ia, ia.active, 1, 1, 0)
              end
            end
          end
        end

        -- fade-out opacity ----------------------------------------------
        if b.fading and F.opacity then
          if b.textTask then b.textTask:setOpacity(b.fadeOpacity) end
          if b.bg then
            local c = b.bgColor
            b.bg:setColor(vec(c.x, c.y, c.z, (c.w or 1) * b.fadeOpacity))
          end
          if ia and ia.revealed then ia.active:setColor(vec(1, 1, 1, b.fadeOpacity)) end
        end
      end

      i = i + 1
    end
  end
end

events.RENDER:register(update)