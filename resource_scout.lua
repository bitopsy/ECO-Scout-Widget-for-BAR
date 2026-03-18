-- resource_scout.lua
-- Beyond All Reason widget — Eco / BP / AV / DV + Metal & Energy time-series charts
-- Place in: Beyond All Reason/LuaUI/Widgets/

function widget:GetInfo()
    return {
        name    = "Eco Scout",
        desc    = "Eco stats, power values, and 10-min metal/energy production charts",
        author  = "goddot",
        date    = "2026",
        license = "GNU GPL v2",
        layer   = 0,
        enabled = true,
    }
end

-- ─── Config ───────────────────────────────────────────────────────────────────

local CFG = {
    w            = 255,
    bgAlpha      = 0.82,
    fontSize     = 13,
    padding      = 9,
    rowH         = 20,
    intervals    = { 0.25, 0.5, 1.0, 2.0, 5.0 },
    intervalIdx  = 2,
    -- Chart config
    chartH       = 54,    -- height of each mini chart panel
    chartGap     = 4,     -- gap between the two charts
    chartPadL    = 28,    -- left pad for y labels
    chartPadB    = 14,    -- bottom pad for x labels
    chartPadT    = 12,    -- top pad for metric label
    historyMins  = 10,
    curveSegs    = 10,    -- Catmull-Rom subdivisions per segment
}

local FRAMES_PER_MIN = 30 * 60

-- Position — bottom-left origin
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
local spGetGameFrame     = Spring.GetGameFrame

local glRect       = gl.Rect
local glColor      = gl.Color
local glText       = gl.Text
local glVertex     = gl.Vertex
local glBeginEnd   = gl.BeginEnd
local GL_LINE_LOOP  = GL.LINE_LOOP
local GL_LINES      = GL.LINES
local GL_LINE_STRIP = GL.LINE_STRIP

local mfloor = math.floor
local mmin   = math.min
local mmax   = math.max
local mcos   = math.cos
local msin   = math.sin
local mpi    = math.pi

-- ─── Screen size ──────────────────────────────────────────────────────────────

local screenW = 1280
local screenH = 768

local function updateScreenSize()
    local info = { Spring.GetViewGeometry() }
    if info[3] and info[3] > 100 then
        screenW = info[3]
        screenH = info[4]
    end
end

-- Total widget height = stats box + chart gap + 2 charts
local function statsBoxH()
    return CFG.padding * 2 + CFG.rowH * 14
end

local function totalH()
    return statsBoxH()
        + CFG.chartGap
        + (CFG.chartPadT + CFG.chartH + CFG.chartPadB)   -- metal chart
        + CFG.chartGap
        + (CFG.chartPadT + CFG.chartH + CFG.chartPadB)   -- energy chart
end

local function clampPos()
    if posX < 0 then posX = 0 end
    if posY < 0 then posY = 0 end
    if posX + CFG.w > screenW then posX = screenW - CFG.w end
    if posY + totalH() > screenH then posY = screenH - totalH() end
end

-- ─── Unit def classification ──────────────────────────────────────────────────

local udCache = {}

local function classifyUnitDefs()
    for udid, ud in pairs(UnitDefs) do
        local cost = ud.metalCost or 0
        local isBP, isArmy, isDef = false, false, false
        local bp = 0
        if ud.buildSpeed and ud.buildSpeed > 0 then isBP = true; bp = ud.buildSpeed end
        local canAttack = ud.weapons and #ud.weapons > 0
        local isStatic  = (not ud.canMove) or (ud.speed == 0)
        if canAttack and isStatic and not isBP then isDef = true end
        if canAttack and ud.canMove and ud.speed and ud.speed > 0 then isArmy = true end
        if cost > 0 and (isBP or isArmy or isDef) then
            udCache[udid] = { cost=cost, isBP=isBP, isArmy=isArmy, isDef=isDef, bp=bp }
        end
    end
end

-- ─── State ────────────────────────────────────────────────────────────────────

local stats = {
    metalIncome=0.0, metalExpense=0.0, metalNet=0.0,
    metalStorage=0,  metalStorageCap=0,
    metalFull=false, metalStall=false,
    energyIncome=0.0, energyExpense=0.0, energyNet=0.0,
    energyStorage=0,  energyStorageCap=0,
    energyFull=false, energyStall=false,
    bp=0, armyValue=0, defValue=0,
}

local myTeamID  = 0
local ecoTimer  = 0
local unitTimer = 0
local UNIT_INTERVAL = 1.0

-- ─── History ──────────────────────────────────────────────────────────────────
-- Sampled every eco interval, bucketed by game minute.
-- history.metal / history.energy each hold arrays of { minute, income, expense }

local history = {
    metal  = {},   -- array of { m=minute, inc=val, exp=val }
    energy = {},
}

local function currentMinute()
    return mfloor((spGetGameFrame and spGetGameFrame() or 0) / FRAMES_PER_MIN)
end

local function pushHistory(minute, mInc, mExp, eInc, eExp)
    local cutoff = minute - CFG.historyMins

    -- Metal: overwrite or append for this minute
    local function push(tbl, inc, exp)
        -- Find existing entry for this minute
        for i = #tbl, 1, -1 do
            if tbl[i].m == minute then
                tbl[i].inc = inc; tbl[i].exp = exp
                return
            end
        end
        tbl[#tbl + 1] = { m=minute, inc=inc, exp=exp }
        -- Prune old entries
        local kept = {}
        for _, e in ipairs(tbl) do
            if e.m >= cutoff then kept[#kept + 1] = e end
        end
        -- sort ascending by minute
        table.sort(kept, function(a,b) return a.m < b.m end)
        for i = 1, #tbl do tbl[i] = nil end
        for i, v in ipairs(kept) do tbl[i] = v end
    end

    push(history.metal,  mInc, mExp)
    push(history.energy, eInc, eExp)
end

-- ─── Refresh ──────────────────────────────────────────────────────────────────

local function refreshEco()
    local mCur, mStore, _, mInc, mExp = spGetTeamResources(myTeamID, "metal")
    local eCur, eStore, _, eInc, eExp = spGetTeamResources(myTeamID, "energy")
    mCur=mCur or 0; mStore=mStore or 0; mInc=mInc or 0; mExp=mExp or 0
    eCur=eCur or 0; eStore=eStore or 0; eInc=eInc or 0; eExp=eExp or 0

    stats.metalIncome     = mfloor(mInc*10)/10
    stats.metalExpense    = mfloor(mExp*10)/10
    stats.metalNet        = mfloor((mInc-mExp)*10)/10
    stats.metalStorage    = mfloor(mCur)
    stats.metalStorageCap = mfloor(mStore)
    stats.metalFull       = mStore>0 and (mCur/mStore)>0.95
    stats.metalStall      = mInc>0 and mExp>mInc*1.05

    stats.energyIncome     = mfloor(eInc*10)/10
    stats.energyExpense    = mfloor(eExp*10)/10
    stats.energyNet        = mfloor((eInc-eExp)*10)/10
    stats.energyStorage    = mfloor(eCur)
    stats.energyStorageCap = mfloor(eStore)
    stats.energyFull       = eStore>0 and (eCur/eStore)>0.95
    stats.energyStall      = eInc>0 and eExp>eInc*1.05

    pushHistory(currentMinute(), mInc, mExp, eInc, eExp)
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
                if info.isArmy then army = army + mfloor(info.cost*frac) end
                if info.isDef  then def  = def  + mfloor(info.cost*frac) end
            end
        end
    end
    stats.bp        = mfloor(bp)
    stats.armyValue = army
    stats.defValue  = def
end

-- ─── Catmull-Rom smooth curve ─────────────────────────────────────────────────

local function catmullRom(x0,y0, x1,y1, x2,y2, x3,y3, t)
    local t2, t3 = t*t, t*t*t
    local rx = 0.5*((-x0+3*x1-3*x2+x3)*t3+(2*x0-5*x1+4*x2-x3)*t2+(-x0+x2)*t+2*x1)
    local ry = 0.5*((-y0+3*y1-3*y2+y3)*t3+(2*y0-5*y1+4*y2-y3)*t2+(-y0+y2)*t+2*y1)
    return rx, ry
end

local function drawSmoothedLine(pts, segs)
    local n = #pts
    if n == 0 then return end
    if n == 1 then
        glBeginEnd(GL_LINE_LOOP, function()
            for s = 0, 5 do
                local a = s*mpi/3
                glVertex(pts[1][1]+mcos(a)*2, pts[1][2]+msin(a)*2)
            end
        end)
        return
    end
    if n == 2 then
        glBeginEnd(GL_LINE_STRIP, function()
            glVertex(pts[1][1], pts[1][2])
            glVertex(pts[2][1], pts[2][2])
        end)
        return
    end
    -- Build extended list with phantom endpoints
    local ext = {}
    ext[1] = { 2*pts[1][1]-pts[2][1], 2*pts[1][2]-pts[2][2] }
    for i = 1, n do ext[i+1] = pts[i] end
    ext[n+2] = { 2*pts[n][1]-pts[n-1][1], 2*pts[n][2]-pts[n-1][2] }

    glBeginEnd(GL_LINE_STRIP, function()
        for i = 1, n-1 do
            local p0,p1,p2,p3 = ext[i],ext[i+1],ext[i+2],ext[i+3]
            for s = 0, segs do
                local rx,ry = catmullRom(
                    p0[1],p0[2], p1[1],p1[2],
                    p2[1],p2[2], p3[1],p3[2], s/segs)
                glVertex(rx, ry)
            end
        end
    end)
end

-- ─── Drawing: stats box ───────────────────────────────────────────────────────

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

local function fmtVal(v)
    if v >= 10000 then return string.format("%.0fk", v/1000)
    elseif v >= 1000 then return string.format("%.1fk", v/1000)
    elseif v >= 10   then return string.format("%.0f",  v)
    else                  return string.format("%.1f",  v) end
end

local function netRGB(v)
    if v > 0 then return 0.35, 0.88, 0.55
    elseif v < 0 then return 0.88, 0.32, 0.32
    else return 0.55, 0.58, 0.65 end
end

local function drawStatsBox()
    local x  = posX
    local y  = posY + totalH() - statsBoxH()   -- stats box sits at the top
    local w  = CFG.w
    local p  = CFG.padding
    local rh = CFG.rowH
    local fs = CFG.fontSize
    local h  = statsBoxH()

    glColor(0.05, 0.06, 0.09, CFG.bgAlpha)
    glRect(x, y, x+w, y+h)
    glColor(0.28, 0.48, 0.78, 0.55)
    gl.LineWidth(1.0)
    glBeginEnd(GL_LINE_LOOP, function()
        glVertex(x,   y);   glVertex(x+w, y)
        glVertex(x+w, y+h); glVertex(x,   y+h)
    end)

    local tx = x + p
    local ty = y + h - p - rh + 3

    -- Title
    glColor(0.72, 0.86, 1.0, 1.0)
    glText("Eco Scout", tx, ty, fs+1, "o")
    local iv    = CFG.intervals[CFG.intervalIdx]
    local ivStr = iv < 1 and (mfloor(iv*1000).."ms") or (iv.."s")
    glColor(0.38, 0.42, 0.50, 0.9)
    glText("upd:"..ivStr.." (scroll)", tx+w*0.42, ty, fs-3, "o")
    ty = ty - rh

    sep(x, ty+rh-4, w, p, 0.45)

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
        local bx=tx+w*0.40; local bw=w*0.55
        local bh=rh*0.42;   local by=ty+3
        glColor(0.13, 0.14, 0.18, 1.0)
        glRect(bx, by, bx+bw, by+bh)
        local frac = cap>0 and mmin(cur/cap,1.0) or 0
        local fr,fg,fb
        if warn and frac>0.95 then fr,fg,fb=0.88,0.32,0.32
        elseif frac>0.75      then fr,fg,fb=0.96,0.68,0.14
        else                       fr,fg,fb=br,bg,bb end
        glColor(fr, fg, fb, 0.82)
        glRect(bx, by, bx+bw*frac, by+bh)
        glColor(0.82, 0.86, 0.92, 1.0)
        glText(mfloor(frac*100).."%  "..cur.."/"..cap, bx+3, ty, fs-1, "o")
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

-- ─── Drawing: mini time-series chart panel ────────────────────────────────────
-- chartY = bottom-left y of the whole panel block (padT + chartH + padB)

local function drawChart(chartY, tbl, label, incR, incG, incB, expR, expG, expB)
    local x    = posX
    local w    = CFG.w
    local pL   = CFG.chartPadL
    local pB   = CFG.chartPadB
    local pT   = CFG.chartPadT
    local ch   = CFG.chartH
    local fs   = 8

    -- Panel area boundaries
    local panelH = pT + ch + pB
    local cx     = x + pL            -- chart left
    local cw     = w - pL - 4        -- chart width
    local cy     = chartY + pB       -- chart bottom
    -- (chart top = cy + ch)

    -- Background
    glColor(0.04, 0.05, 0.08, CFG.bgAlpha)
    glRect(x, chartY, x+w, chartY+panelH)

    -- Border
    glColor(0.22, 0.30, 0.42, 0.50)
    gl.LineWidth(1.0)
    glBeginEnd(GL_LINE_LOOP, function()
        glVertex(x,   chartY);         glVertex(x+w, chartY)
        glVertex(x+w, chartY+panelH);  glVertex(x,   chartY+panelH)
    end)

    -- Label top-left
    glColor(0.75, 0.80, 0.88, 0.95)
    glText(label, x+pL, chartY+panelH-2, fs+1, "ol")

    -- Legend: income / expense
    glColor(incR, incG, incB, 0.9)
    glText("income", x+w*0.52, chartY+panelH-2, fs, "ol")
    glColor(expR, expG, expB, 0.9)
    glText("expense", x+w*0.75, chartY+panelH-2, fs, "ol")

    -- Need at least 1 point
    if #tbl == 0 then
        glColor(0.40, 0.43, 0.48, 0.6)
        glText("no data yet", cx + cw*0.5, cy + ch*0.5, fs, "oc")
        return
    end

    -- Compute x window
    local nowMin = currentMinute()
    local oldMin = mmax(0, nowMin - CFG.historyMins)
    local spanMin = nowMin - oldMin

    -- Find max value across all history for y scaling
    local yMax = 1
    for _, e in ipairs(tbl) do
        if e.inc > yMax then yMax = e.inc end
        if e.exp > yMax then yMax = e.exp end
    end

    -- Y grid lines at 25%, 50%, 75%, 100%
    for t = 1, 4 do
        local frac = t / 4
        local gy   = cy + frac * ch
        glColor(1, 1, 1, t==4 and 0.10 or 0.05)
        glBeginEnd(GL_LINES, function()
            glVertex(cx,    gy); glVertex(cx+cw, gy)
        end)
    end

    -- Y max label
    glColor(0.50, 0.53, 0.58, 0.75)
    glText(fmtVal(yMax), cx-2, cy+ch-1, fs, "or")

    -- X axis baseline
    glColor(1, 1, 1, 0.20)
    glBeginEnd(GL_LINES, function()
        glVertex(cx, cy); glVertex(cx+cw, cy)
    end)

    -- X tick labels (every 2 minutes on the bottom)
    local step = CFG.historyMins <= 5 and 1 or 2
    for t = 0, CFG.historyMins, step do
        local frac = spanMin > 0 and (t / CFG.historyMins) or 0
        local lx   = cx + frac * cw
        glColor(0.45, 0.48, 0.54, 0.75)
        glText((oldMin+t).."m", lx, chartY+2, fs, "oc")
    end

    -- Build screen points for income and expense
    local incPts = {}
    local expPts = {}
    for _, e in ipairs(tbl) do
        local xfrac = spanMin > 0 and mmin((e.m - oldMin) / spanMin, 1.0) or 1.0
        if xfrac >= 0 then
            local lx = cx + xfrac * cw
            incPts[#incPts+1] = { lx, cy + (yMax>0 and mmin(e.inc/yMax,1)*ch or 0) }
            expPts[#expPts+1] = { lx, cy + (yMax>0 and mmin(e.exp/yMax,1)*ch or 0) }
        end
    end

    -- Draw smooth income line
    if #incPts > 0 then
        gl.LineWidth(1.5)
        glColor(incR, incG, incB, 0.88)
        drawSmoothedLine(incPts, CFG.curveSegs)
        -- dot at latest
        local lp = incPts[#incPts]
        glColor(incR, incG, incB, 1.0)
        glBeginEnd(GL_LINE_LOOP, function()
            for s=0,5 do local a=s*mpi/3
                glVertex(lp[1]+mcos(a)*2, lp[2]+msin(a)*2)
            end
        end)
    end

    -- Draw smooth expense line
    if #expPts > 0 then
        gl.LineWidth(1.5)
        glColor(expR, expG, expB, 0.88)
        drawSmoothedLine(expPts, CFG.curveSegs)
        local lp = expPts[#expPts]
        glColor(expR, expG, expB, 1.0)
        glBeginEnd(GL_LINE_LOOP, function()
            for s=0,5 do local a=s*mpi/3
                glVertex(lp[1]+mcos(a)*2, lp[2]+msin(a)*2)
            end
        end)
    end

    gl.LineWidth(1.0)
end

-- ─── Main draw ────────────────────────────────────────────────────────────────

local function drawAll()
    local panelBlock = CFG.chartPadT + CFG.chartH + CFG.chartPadB

    -- Energy chart: lowest panel
    local eChartY = posY
    -- Metal chart: above energy chart
    local mChartY = posY + panelBlock + CFG.chartGap

    drawChart(mChartY, history.metal,
              "Metal m/s",
              0.35, 0.65, 1.0,    -- income: blue
              0.88, 0.42, 0.20)   -- expense: orange-red

    drawChart(eChartY, history.energy,
              "Energy e/s",
              0.96, 0.78, 0.14,   -- income: amber
              0.72, 0.30, 0.88)   -- expense: purple

    drawStatsBox()
end

-- ─── Widget callbacks ─────────────────────────────────────────────────────────

function widget:Initialize()
    myTeamID = spGetMyTeamID() or 0
    classifyUnitDefs()
    updateScreenSize()
    posX = screenW - CFG.w - 10
    posY = screenH - totalH() - 60
    refreshEco()
    refreshUnits()
end

function widget:ViewResize(vw, vh)
    screenW = vw
    screenH = vh
    posX = screenW - CFG.w - 10
    posY = screenH - totalH() - 60
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
    drawAll()
end

-- ─── Dragging ─────────────────────────────────────────────────────────────────

local dragging = false
local dragOffX = 0
local dragOffY = 0

local function inWidget(mx, my)
    return mx >= posX and mx <= posX + CFG.w
       and my >= posY and my <= posY + totalH()
end

function widget:MousePress(mx, my, btn)
    if btn ~= 1 then return false end
    if inWidget(mx, my) then
        dragging = true
        dragOffX = mx - posX
        dragOffY = my - posY
        return true
    end
    return false
end

function widget:MouseMove(mx, my, dx, dy)
    if dragging then
        posX = mx - dragOffX
        posY = my - dragOffY
        clampPos()
    end
end

function widget:MouseRelease(mx, my, btn)
    if btn == 1 then dragging = false end
end

-- ─── Scroll: cycle update interval ───────────────────────────────────────────

function widget:MouseWheel(up, value)
    local mx, my = spGetMouseState()
    if not inWidget(mx, my) then return false end
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