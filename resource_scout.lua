-- resource_scout.lua
-- Beyond All Reason widget — Eco / BP / Army Value / Defense Value
-- Place in: Beyond All Reason/LuaUI/Widgets/
-- Author goddot -- bitopsy.com 


function widget:GetInfo()
    return {
        name    = "Eco Scout",
        desc    = "Eco stats, build power, army value and defense value in metal",
        author  = "goddot",
        date    = "2026",
        license = "GNU GPL v2",
        layer   = 0,
        enabled = true,
    }
end

-- ─── Config ───────────────────────────────────────────────────────────────────

local CFG = {
    w           = 255,
    bgAlpha     = 0.82,
    fontSize    = 13,
    padding     = 9,
    rowH        = 20,
    intervals   = { 0.25, 0.5, 1.0, 2.0, 5.0 },
    intervalIdx = 2,
}

-- Fixed starting position — bottom-left origin, placed near top-right
-- Will be updated on ViewResize and clamped on drag
local posX = 900
local posY = 400

-- ─── Spring API locals ────────────────────────────────────────────────────────

local spGetAllUnits      = Spring.GetAllUnits
local spGetUnitDefID     = Spring.GetUnitDefID
local spGetUnitTeam      = Spring.GetUnitTeam
local spGetUnitHealth    = Spring.GetUnitHealth
local spGetMyTeamID      = Spring.GetMyTeamID
local spGetTeamResources = Spring.GetTeamResources
local spGetMouseState    = Spring.GetMouseState

local glRect       = gl.Rect
local glColor      = gl.Color
local glText       = gl.Text
local glVertex     = gl.Vertex
local glBeginEnd   = gl.BeginEnd
local GL_LINE_LOOP = GL.LINE_LOOP
local GL_LINES     = GL.LINES

-- ─── Screen size ──────────────────────────────────────────────────────────────

local screenW = 1280
local screenH = 768

local function updateScreenSize()
    local vsx, vsy = Spring.GetViewGeometry()
    -- GetViewGeometry returns: x, y, width, height
    -- indices 3 and 4 are width and height
    local info = { Spring.GetViewGeometry() }
    if info[3] and info[3] > 100 then
        screenW = info[3]
        screenH = info[4]
    end
end

local function boxH()
    return CFG.padding * 2 + CFG.rowH * 14
end

local function clampPos()
    if posX < 0 then posX = 0 end
    if posY < 0 then posY = 0 end
    if posX + CFG.w > screenW then posX = screenW - CFG.w end
    if posY + boxH() > screenH then posY = screenH - boxH() end
end

-- ─── Unit def classification ──────────────────────────────────────────────────

local udCache = {}

local function classifyUnitDefs()
    for udid, ud in pairs(UnitDefs) do
        local cost = ud.metalCost or 0
        local isBP, isArmy, isDef = false, false, false
        local bp = 0

        if ud.buildSpeed and ud.buildSpeed > 0 then
            isBP = true
            bp   = ud.buildSpeed
        end

        local canAttack = ud.weapons and #ud.weapons > 0
        local isStatic  = (not ud.canMove) or (ud.speed == 0)

        if canAttack and isStatic and not isBP then
            isDef = true
        end

        if canAttack and ud.canMove and ud.speed and ud.speed > 0 then
            isArmy = true
        end

        if cost > 0 and (isBP or isArmy or isDef) then
            udCache[udid] = { cost = cost, isBP = isBP, isArmy = isArmy,
                              isDef = isDef, bp = bp }
        end
    end
end

-- ─── State ────────────────────────────────────────────────────────────────────

local stats = {
    metalIncome = 0.0, metalExpense = 0.0, metalNet = 0.0,
    metalStorage = 0,  metalStorageCap = 0,
    metalFull = false, metalStall = false,
    energyIncome = 0.0, energyExpense = 0.0, energyNet = 0.0,
    energyStorage = 0,  energyStorageCap = 0,
    energyFull = false, energyStall = false,
    bp = 0, armyValue = 0, defValue = 0,
}

local myTeamID  = 0
local ecoTimer  = 0
local unitTimer = 0
local UNIT_INTERVAL = 1.0

-- ─── Refresh ──────────────────────────────────────────────────────────────────

local function refreshEco()
    local mCur, mStore, _, mInc, mExp = spGetTeamResources(myTeamID, "metal")
    local eCur, eStore, _, eInc, eExp = spGetTeamResources(myTeamID, "energy")
    mCur=mCur or 0; mStore=mStore or 0; mInc=mInc or 0; mExp=mExp or 0
    eCur=eCur or 0; eStore=eStore or 0; eInc=eInc or 0; eExp=eExp or 0

    stats.metalIncome     = math.floor(mInc*10)/10
    stats.metalExpense    = math.floor(mExp*10)/10
    stats.metalNet        = math.floor((mInc-mExp)*10)/10
    stats.metalStorage    = math.floor(mCur)
    stats.metalStorageCap = math.floor(mStore)
    stats.metalFull       = mStore>0 and (mCur/mStore)>0.95
    stats.metalStall      = mInc>0 and mExp>mInc*1.05

    stats.energyIncome     = math.floor(eInc*10)/10
    stats.energyExpense    = math.floor(eExp*10)/10
    stats.energyNet        = math.floor((eInc-eExp)*10)/10
    stats.energyStorage    = math.floor(eCur)
    stats.energyStorageCap = math.floor(eStore)
    stats.energyFull       = eStore>0 and (eCur/eStore)>0.95
    stats.energyStall      = eInc>0 and eExp>eInc*1.05
end

local function refreshUnits()
    local bp, army, def = 0, 0, 0
    local units = spGetAllUnits()
    for i = 1, #units do
        local uid = units[i]
        if spGetUnitTeam(uid) == myTeamID then
            local info = udCache[spGetUnitDefID(uid)]
            if info then
                local hp, maxHp = spGetUnitHealth(uid)
                local frac = (hp and maxHp and maxHp>0) and (hp/maxHp) or 1.0
                if info.isBP   then bp   = bp   + info.bp end
                if info.isArmy then army = army + math.floor(info.cost*frac) end
                if info.isDef  then def  = def  + math.floor(info.cost*frac) end
            end
        end
    end
    stats.bp        = math.floor(bp)
    stats.armyValue = army
    stats.defValue  = def
end

-- ─── Drawing ──────────────────────────────────────────────────────────────────

local function sep(x, y, w, p, a)
    glColor(0.3, 0.5, 0.8, a or 0.28)
    glBeginEnd(GL_LINES, function()
        glVertex(x+p, y); glVertex(x+w-p, y)
    end)
end

local function fmtK(n)
    if n >= 1000 then return string.format("%.1fk", n/1000) end
    return tostring(n)
end

local function netRGB(v)
    if v > 0 then return 0.35, 0.88, 0.55
    elseif v < 0 then return 0.88, 0.32, 0.32
    else return 0.55, 0.58, 0.65 end
end

local function drawBox()
    local x  = posX
    local y  = posY
    local w  = CFG.w
    local p  = CFG.padding
    local rh = CFG.rowH
    local fs = CFG.fontSize
    local h  = boxH()

    glColor(0.05, 0.06, 0.09, CFG.bgAlpha)
    glRect(x, y, x+w, y+h)

    glColor(0.28, 0.48, 0.78, 0.55)
    gl.LineWidth(1.0)
    glBeginEnd(GL_LINE_LOOP, function()
        glVertex(x,   y);   glVertex(x+w, y)
        glVertex(x+w, y+h); glVertex(x,   y+h)
    end)

    local tx = x + p
    -- Start from top of box, render downward
    -- In BAR bottom-left origin: top of box = y+h, we step down by rh each row
    local ty = y + h - p - rh + 3

    -- Title
    glColor(0.72, 0.86, 1.0, 1.0)
    glText("Eco Scout", tx, ty, fs+1, "o")
    local iv    = CFG.intervals[CFG.intervalIdx]
    local ivStr = iv < 1 and (math.floor(iv*1000).."ms") or (iv.."s")
    glColor(0.38, 0.42, 0.50, 0.9)
    glText("by goddot -- upd:"..ivStr.." (scroll)", tx + w*0.42, ty, fs-3, "o")
    ty = ty - rh

    sep(x, ty+rh-4, w, p, 0.45)

    -- ECO header
    glColor(0.44, 0.50, 0.60, 0.85)
    glText("ECO", tx, ty, fs-2, "o")
    glText("income",  tx+w*0.46, ty, fs-2, "o")
    glText("expense", tx+w*0.70, ty, fs-2, "o")
    ty = ty - rh*0.82

    local function ecoRow(lbl, inc, exp, ir, ig, ib, stall, full)
        glColor(0.60, 0.65, 0.73, 1.0)
        glText(lbl, tx, ty, fs, "o")
        glColor(ir, ig, ib, 1.0)
        glText(string.format("%.1f", inc), tx+w*0.48, ty, fs, "o")
        local er,eg,eb
        if stall then er,eg,eb=0.88,0.32,0.32
        elseif full then er,eg,eb=0.96,0.68,0.14
        else er,eg,eb=0.50,0.53,0.60 end
        glColor(er, eg, eb, 1.0)
        glText(string.format("%.1f", exp), tx+w*0.72, ty, fs, "o")
        ty = ty - rh
    end

    ecoRow("Metal m/s",  stats.metalIncome,  stats.metalExpense,
           0.35,0.65,1.0,   stats.metalStall,  stats.metalFull)
    ecoRow("Energy e/s", stats.energyIncome, stats.energyExpense,
           0.96,0.68,0.14,  stats.energyStall, stats.energyFull)

    local function storBar(lbl, cur, cap, br, bg, bb, warn)
        glColor(0.60, 0.65, 0.73, 1.0)
        glText(lbl, tx, ty, fs, "o")
        local bx = tx+w*0.40; local bw = w*0.55
        local bh = rh*0.42;   local by = ty+3
        glColor(0.13, 0.14, 0.18, 1.0)
        glRect(bx, by, bx+bw, by+bh)
        local frac = cap>0 and math.min(cur/cap,1.0) or 0
        local fr,fg,fb
        if warn and frac>0.95 then fr,fg,fb=0.88,0.32,0.32
        elseif frac>0.75      then fr,fg,fb=0.96,0.68,0.14
        else                       fr,fg,fb=br,bg,bb end
        glColor(fr, fg, fb, 0.82)
        glRect(bx, by, bx+bw*frac, by+bh)
        glColor(0.82, 0.86, 0.92, 1.0)
        glText(math.floor(frac*100).."%  "..cur.."/"..cap, bx+3, ty, fs-1, "o")
        ty = ty - rh
    end

    storBar("M storage", stats.metalStorage,  stats.metalStorageCap,
            0.35,0.65,1.0,  stats.metalFull)
    storBar("E storage", stats.energyStorage, stats.energyStorageCap,
            0.96,0.68,0.14, stats.energyFull)

    sep(x, ty+rh-4, w, p)

    local function netRow(lbl, net, stall)
        glColor(0.60, 0.65, 0.73, 1.0)
        glText(lbl, tx, ty, fs, "o")
        local nr,ng,nb = netRGB(net)
        glColor(nr, ng, nb, 1.0)
        local sign = net>=0 and "+" or ""
        glText(sign..string.format("%.1f", net), tx+w*0.50, ty, fs, "o")
        if stall then
            glColor(0.88, 0.32, 0.32, 1.0)
            glText("STALL", tx+w*0.73, ty, fs-1, "o")
        end
        ty = ty - rh
    end

    netRow("Metal net",  stats.metalNet,  stats.metalStall)
    netRow("Energy net", stats.energyNet, stats.energyStall)

    sep(x, ty+rh-4, w, p)

    -- POWER section
    glColor(0.44, 0.50, 0.60, 0.85)
    glText("POWER", tx, ty, fs-2, "o")
    ty = ty - rh*0.82

    local function valRow(lbl, val, vr, vg, vb)
        glColor(0.60, 0.65, 0.73, 1.0)
        glText(lbl, tx, ty, fs, "o")
        glColor(vr, vg, vb, 1.0)
        glText(fmtK(val), tx+w*0.52, ty, fs, "o")
        ty = ty - rh
    end

    valRow("Build power",   stats.bp,        0.60, 0.88, 0.72)
    valRow("Army value  M", stats.armyValue, 0.96, 0.42, 0.35)
    valRow("Defense val M", stats.defValue,  0.72, 0.55, 0.96)
end

-- ─── Widget callbacks ─────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID() or 0
    classifyUnitDefs()
    updateScreenSize()
    -- Place near top-right using bottom-left origin
    posX = screenW - CFG.w - 10
    posY = screenH - boxH() - 60
    refreshEco()
    refreshUnits()
end

function widget:ViewResize(vw, vh)
    screenW = vw
    screenH = vh
    -- Re-anchor to top-right on resize
    posX = screenW - CFG.w - 10
    posY = screenH - boxH() - 60
end

function widget:Update(dt)
    local interval = CFG.intervals[CFG.intervalIdx]
    ecoTimer  = ecoTimer  + dt
    unitTimer = unitTimer + dt
    if ecoTimer >= interval then
        ecoTimer = 0
        refreshEco()
    end
    if unitTimer >= UNIT_INTERVAL then
        unitTimer = 0
        refreshUnits()
    end
end

function widget:DrawScreen()
    drawBox()
end

-- ─── Dragging ─────────────────────────────────────────────────────────────────

local dragging = false
local dragOffX = 0
local dragOffY = 0

local function inBox(mx, my)
    -- BAR passes mouse coords in top-left origin; convert to bottom-left
    local fy = screenH - my
    return mx >= posX and mx <= posX + CFG.w
       and fy >= posY and fy <= posY + boxH()
end

function widget:MousePress(mx, my, btn)
    if btn ~= 1 then return false end
    if inBox(mx, my) then
        local fy = screenH - my
        dragging = true
        dragOffX = mx - posX
        dragOffY = fy - posY
        return true
    end
    return false
end

function widget:MouseMove(mx, my, dx, dy)
    if dragging then
        local fy = screenH - my
        posX = mx - dragOffX
        posY = fy - dragOffY
        clampPos()
    end
end

function widget:MouseRelease(mx, my, btn)
    if btn == 1 then dragging = false end
end

-- ─── Scroll: cycle update interval ───────────────────────────────────────────

function widget:MouseWheel(up, value)
    local mx, my = spGetMouseState()
    if not inBox(mx, my) then return false end
    if up then
        CFG.intervalIdx = CFG.intervalIdx - 1
        if CFG.intervalIdx < 1 then CFG.intervalIdx = #CFG.intervals end
    else
        CFG.intervalIdx = CFG.intervalIdx + 1
        if CFG.intervalIdx > #CFG.intervals then CFG.intervalIdx = 1 end
    end
    ecoTimer = 0
    return true
end