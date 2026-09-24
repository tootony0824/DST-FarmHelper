--==============================================================================
--  农事手册 (Farm Helper)  ·  modmain.lua
--
--  一个纯客户端的种地信息面板。不改任何游戏数据，只把游戏里本来就有的
--  数据整理出来给你看。
--
--  内容：
--    1. 当前季节 + 剩余天数
--    2. 14 种作物的「作物名 / 种子名」对照
--    3. 每种作物消耗的三种养分点数
--    4. 当前季节适合种的作物会高亮
--    5. 养分循环的配比原则 + 一个现成可用的例子
--
--  面板可以按住标题栏拖动；位置记在本地，下次进游戏还在原地。
--
--  数据来源：游戏本体 data/databundles/scripts.zip
--            -> scripts/prefabs/farm_plant_defs.lua
--  养分数组的顺序固定为 { 催长剂, 堆肥, 粪肥 }
--==============================================================================

--==============================================================================
--  0. 把 mod 的运行环境接回真正的全局表（必须放在最前面）
--
--  modmain 并不跑在 _G 里。mods.lua 的 CreateEnvironment() 现搭了一张白名单表，
--  里面只有 print / pairs / ipairs / math / table / string / type / tostring /
--  require / Class / TUNING / GLOBAL / modname / MODROOT 这几个名字，
--  而且**没有 __index 兜底**。
--
--  后果：游戏里的普通全局在 modmain 里裸写全是 nil ——
--  ANCHOR_LEFT、ANCHOR_TOP、MOUSEBUTTON_LEFT、TALKINGFONT、TheSim、
--  TheInput、TheWorld、STRINGS、tonumber…
--  它们不会报「未定义」，只是安静地变成 nil，然后在别处炸掉或者干脆不生效。
--  这一版之前面板崩在 SetHAnchor(nil) 就是这个原因。
--
--  挂上 __index 让查不到的名字回落到 _G。env 自己的键优先级更高，
--  所以 GetModConfigData 这种由 modutil 按 mod 名绑定后再塞进 env 的接口不受影响
--  （它反而不存在于 _G，不能改成 GLOBAL.GetModConfigData）。
--==============================================================================

GLOBAL.setmetatable(env, { __index = function(_, key) return GLOBAL.rawget(GLOBAL, key) end })

-- 自检：上面那行要是没生效，日志里直接点名，省得靠猜。
do
    local need = { "ANCHOR_LEFT", "ANCHOR_TOP", "MOUSEBUTTON_LEFT", "TALKINGFONT", "tonumber",
                   "TheSim", "TheInput" }
    local lost = {}
    for _, key in ipairs(need) do
        if GLOBAL.rawget(GLOBAL, key) == nil then
            table.insert(lost, key)
        end
    end
    if #lost > 0 then
        print("[FarmHelper] 环境自检失败，全局表里没有：" .. table.concat(lost, ", "))
    else
        print("[FarmHelper] 环境自检通过")
    end
end

local Widget = require("widgets/widget")
local Image  = require("widgets/image")
local Text   = require("widgets/text")

-- 读取玩家在游戏内「模组设置」里选的选项
local OPEN_KEY   = GetModConfigData("open_key") or 104   -- 104 = KEY_H
local PAGE_KEY   = GetModConfigData("page_key") or 106   -- 106 = KEY_J
local START_OPEN = GetModConfigData("start_open")

--==============================================================================
--  一、作物数据
--==============================================================================

-- 三种养分的消耗档位。直接读游戏常量，这样游戏以后调数值也不会失准。
local S = TUNING.FARM_PLANT_CONSUME_NUTRIENT_LOW    -- 低 = 2
local M = TUNING.FARM_PLANT_CONSUME_NUTRIENT_MED    -- 中 = 4
local L = TUNING.FARM_PLANT_CONSUME_NUTRIENT_HIGH   -- 高 = 8

-- consume 的顺序 = { 催长剂, 堆肥, 粪肥 }
-- 按「主要消耗哪一种」分三组排列，方便和底部的配比说明对照着看。
local CROPS =
{
    -- ── 主要消耗生长配方 ──────────────────────────────
    { id = "carrot",      consume = { M, 0, 0 }, seasons = { autumn = true, winter = true, spring = true } },
    { id = "pumpkin",     consume = { M, 0, 0 }, seasons = { autumn = true, winter = true } },
    { id = "onion",       consume = { L, 0, 0 }, seasons = { autumn = true, spring = true, summer = true } },
    { id = "pomegranate", consume = { L, 0, 0 }, seasons = { spring = true, summer = true } },
    { id = "tomato",      consume = { S, S, 0 }, seasons = { autumn = true, spring = true, summer = true } },

    -- ── 主要消耗堆肥 ─────────────────────────────────
    { id = "corn",        consume = { 0, M, 0 }, seasons = { autumn = true, spring = true, summer = true } },
    { id = "asparagus",   consume = { 0, M, 0 }, seasons = { winter = true, spring = true } },
    { id = "garlic",      consume = { 0, L, 0 }, seasons = { autumn = true, winter = true, spring = true, summer = true } },
    { id = "durian",      consume = { 0, L, 0 }, seasons = { spring = true } },
    { id = "watermelon",  consume = { 0, S, S }, seasons = { spring = true, summer = true } },

    -- ── 主要消耗粪肥 ─────────────────────────────────
    { id = "potato",      consume = { 0, 0, M }, seasons = { autumn = true, winter = true, spring = true } },
    { id = "eggplant",    consume = { 0, 0, M }, seasons = { autumn = true, spring = true } },
    { id = "dragonfruit", consume = { 0, 0, L }, seasons = { spring = true, summer = true } },
    { id = "pepper",      consume = { 0, 0, L }, seasons = { autumn = true, summer = true } },
}

-- 留种优先级（v2.6.5）：灰机 wiki「耕种入门与常用配比速查」里的留种建议。
-- 排序时用它破平 —— 同样是零和配比，优先推荐性价比高的那些作物。
--   留 = 2：土豆、番茄、南瓜、火龙果、大蒜
--   可留 = 1：玉米、芦笋、洋葱、辣椒
--   不留 = 0：胡萝卜、茄子、西瓜、榴莲、石榴（西瓜「仅夏天用作临时降温」）
local KEEP = {
    potato = 2, tomato = 2, pumpkin = 2, dragonfruit = 2, garlic = 2,
    corn = 1, asparagus = 1, onion = 1, pepper = 1,
    carrot = 0, eggplant = 0, watermelon = 0, durian = 0, pomegranate = 0,
}
local function KeepScore(items)
    local s = 0
    for _, it in ipairs(items) do
        s = s + (KEEP[it.id] or 0) * it.n
    end
    return s
end

-- ★★★ v2.6.7：删掉了「肥料物品表」（原来是 12 种）和它撑起来的整块 UI。
--
--  为什么删：那张表的唯一用途是第二页的「肥料库存输入网格」，而**没有任何代码在读它**。
--  v2.6.0 把配平器改成「按地皮找零和配比」之后，"零和"本身就意味着不用施肥，
--  「库存 → 缺口 → 选方案」这条链在概念上就淘汰了 —— 我换了算法，却把输入 UI 留着了。
--  表现最坏的那种静默失效：玩家认真填肥料、点配平，结果**一个字都不会变**。
--  （独立审查（不带记忆那种）把这条列为最严重问题。）
--
--  肥料数值本身没错，留档在这儿 —— 以后真要做「手里种子凑不出零和时的降级方案」
--  再把它接回来（那时才有人读它）。来源：tuning.lua + fertilizer_nutrient_defs.lua
--  + standardcomponents.lua:1797（物品是 deployable，一次全加到落点那一格，每类钳 0~100）：
--     粪便 {0,0,8}   蝙蝠粪 {0,0,16}   化肥袋 {0,0,16} ×10 次
--     腐烂物 {0,8,0}  臭鸡蛋 {0,16,0}   堆肥 {0,24,0}
--     腐烂的鱼 {16,0,0}  小腐烂鱼 {8,0,0}  催长剂瓶 {8,0,0}
--     格罗姆粘液 {8,8,8}  堆肥包裹 {24,32,24}  蚊子血袋 {12,12,12}

--==============================================================================
--  二、显示用的常量和颜色
--==============================================================================

local SEASON_ORDER = { "spring", "summer", "autumn", "winter" }
local SEASON_CN    = { spring = "春", summer = "夏", autumn = "秋", winter = "冬" }

-- 面板尺寸和排版。
-- ─────────────────────────────────────────────────────────────────────────────
-- ★ v2.0.0：字号整体放大约 1.5 倍。
--
--   前提是**先量了屏幕**：client_log.txt 里 `CreateWindow: Requesting 1920,1080`
--   —— 游戏跑在 1920×1080，不是之前按 840 高估算的那档。
--   所以面板能从 680×800 放到 1010×1025，字号跟着一路放大。
--
--   放大前的完整参数（v1.9.0）记在 `字号快照.md` 里 ——
--   嫌大就照那张表改回来，不用重新算。
--
--   高度是唯一的硬约束：面板不能超过 1080，还要留边。
--   ★ v2.2.0：面板收到 1000 高、字号回调一档（32→30）—— 用户反馈第一页
--   底部显示不全。另外 OnUpdate 里加了**自动缩放**：窗口/HUD 比面板矮时
--   整块等比缩小，保证从头到尾都在屏幕里（见 UpdateFitScale）。
--   ★ v2.4.0：第二页要塞下 12 种肥料的物品网格，面板 1000 → 1020
--   （1080 屏仍有 60px 余量，自动缩放兜底小窗口）。
-- ─────────────────────────────────────────────────────────────────────────────
local PANEL_W  = 1010
local PANEL_H  = 1040
local ROW_H    = 34       -- 比数据字号(30)大一点，不然行会挤
local ROW_TOP  = -488     -- 第一行数据的 y
local FONT     = TALKINGFONT

-- ★ 内容左边距。所有「贴左边」的元素（标题 / 季节 / 配比 / 布局图 /
--   表头提示 / 底部说明）都用它，表格里的图标左边缘也落在它上面 ——
--   这样左边是一条直线，不会出现「图标比文字靠左一截」的错位。
--   v1.7.0 之前这些地方混用了 COL.name（表格里作物名的 x），
--   结果表格的视觉左边界是图标的 16，而文字是 50，看起来没对齐。
local PAD      = 22

-- 图标边长（作物 / 种子各一个，分别排在两列名字的左边）
local ICON     = 36

-- 表格数据行的字号。单独提出来是因为 RefreshRows 里三处都要用，
-- 而且它和 ROW_H / COL 的列宽是联动的 —— 改这里要一并复核列宽够不够。
-- ★ v2.2.0：32 → 30。用户反馈第一页显示不全，回调一档；
--   另外行高也跟着 36 → 34。
local DATA_SIZE = 30

-- 每一列的横坐标（列头和数据共用，保证对齐）
-- ★ 图标给的是「中心」坐标，不是左边缘 —— Image 的锚点默认居中
--   （文字那边用了 SetHAlign(ANCHOR_LEFT) 所以文字是左边缘）。
--   要让图标左边缘落在 PAD，中心就得写 PAD + ICON/2。
--
-- ★ 列宽的估算基准：中文全角字的 advance ≈ 字号的 1.15 倍
--   （游戏中文走 fallback 字体 Noto Sans CJK，实测 17 号字 ≈ 20px/字）。
--
--   30 号字下：「毛茸茸的种子」6 字 ≈ 207px。「催长剂」表头用 28 号 ≈ 97px，
--   所以养分那三列要隔开 110px 才不会打架。
local COL = {
    icon1  = PAD + ICON / 2,         -- 39   作物图标（中心），左边缘 22
    name   = 68,                     -- 作物名（最长 3 字 ≈ 104px → 到 172）
    icon2  = 200 + ICON / 2,         -- 217  种子图标（中心），左边缘 200
    seed   = 248,                    -- 种子名（最长 6 字 ≈ 207px → 到 455）
    n1     = 500,                    -- 催长剂（净变化，如 "-4"；表头 3 字 ≈ 97px）
    n2     = 610,                    -- 堆肥（表头 2 字 ≈ 64px）
    n3     = 720,                    -- 粪肥
    season = 830,                    -- 适宜季节（4 字 ≈ 129px → 到 959）
}

-- 种植布局图：放在面板右上角（季节 / 配比那两行右侧的空白区）。
-- ★ v2.6.0 整个换掉。以前画的是「9 个格各一株 / 18 个格各一株」两张按格铺的网 ——
--   那是**养分账本**的单位（格），不是种法。玩家照着「一株一格」种下去，
--   株距恰好等于家族判定半径 4，家族 0 通过，一张巨大都出不来。
--   现在改成画「一块地皮（一个 tile）里怎么摆」：
--   一个框 = 一块地皮，里面按配比密排，同种连着放（挤成一堆）。
local LAYOUT_CELL = 34
local UNIT_BOX    = 150          -- 一块地皮的方框 = 4×4 世界单位，占 630~780
-- ★ 土堆按 **3×3 九宫格** 摆 —— 地皮上锄出来就是九宫格的样子。
--   间距 = FARM_TILL_SPACING = 1.25 世界单位；框 150px 代表 4 单位 → 37.5px/单位，
--   所以 1.25 单位 = 46.875px。3×3 跨 93.75px，四周留 28px，正好是「不贴边」的观感。
local UNIT_GAP    = 46.875
local UNIT_ICON   = 28
-- ★ v2.6.9：图区改成**并排画多个方案**（主方案 + 备选），横向最多 3 个位。
--   用户要求「有多余的方案就都提供，多给几个图也可以」。
--   3 个 150px 的框 + 20px 间距 = 490px，从 485 排到 975，都在面板内；
--   左侧四季表只占 22~426，互不干扰。
local UNIT_FIRST_CX = 560        -- 第 1 个图的中心 x（框 150 → 485~635）
local UNIT_STEP     = 170        -- 相邻两图的中心距
local UNIT_CY       = -170       -- 框中心 y → 框占 -95 ~ -245
local UNIT_MAX      = 3          -- 最多画几个方案
local LAYOUT_X1   = 630
local LAYOUT_X2   = 810          -- 图右侧那列短说明（20 号字 8 字 ≈ 184px，到 994）
local LAYOUT_Y    = -142
local LAYOUT_TAG_X = 905

-- 按钮常态 / 悬停时的底色透明度
local BUTTON_ALPHA       = 0.14
local BUTTON_ALPHA_HOVER = 0.30
local TAB_ALPHA_ON       = 0.40    -- 分页标签里「当前页」那个

-- 配色（浅色字，深色底）
local C = {
    title  = { 1.00, 0.92, 0.70 },
    text   = { 0.93, 0.91, 0.85 },
    seed   = { 0.86, 0.85, 0.74 },   -- 种子名：比作物名略暗一档，但要看得清
    dim    = { 0.53, 0.52, 0.48 },
    head   = { 0.78, 0.74, 0.60 },
    now    = { 0.55, 1.00, 0.55 },   -- 当前季节高亮
    note   = { 0.68, 0.66, 0.60 },
    warn   = { 1.00, 0.62, 0.42 },   -- 前提条件 / 容易踩的坑
    minus  = { 1.00, 0.58, 0.50 },   -- 净消耗（表格里的负数）
    plus   = { 0.55, 0.95, 0.62 },   -- 净产出（表格里的正数）
    -- 三种养分的颜色：催长剂=蓝  堆肥=绿  粪肥=橙
    nutrient = {
        { 0.55, 0.80, 1.00 },
        { 0.60, 0.92, 0.55 },
        { 0.98, 0.72, 0.42 },
    },
}

--==============================================================================
--  三、小工具函数
--==============================================================================

-- ★★ v2.1.0 关键修复：SetHAlign(ANCHOR_LEFT) **必须配 SetRegionSize 才生效**。
--
-- 不设 region 时，TextWidget 的 region 就是文字自身的宽度 —— 没有可对齐的余量，
-- 于是 HAlign 等于白写，文字永远**以 x 为中心**左右各展开一半。
-- 后果（这几次一直没修好的真正原因）：
--   想让左边缘落在 x，实际左边缘却在 x - 文字宽/2。
--   标题「农事手册」38 号字约 175px 宽，摆在 x=22 → 实际占 -66 ~ 110，
--   「农事」两个字整块跑到面板左边的黑框外面。
--   同理，表格里每一列都比预想偏左半个字宽 —— 这就是「字体都偏左了」。
--
-- ★ region 框是**以控件位置为中心**的（依据 consolescreen.lua:251-253 和
--   modconfigurationscreen.lua:128：它们都把位置往左挪了「半个 region 宽」
--   再左/右对齐，正好贴到输入框的边缘）。
--   所以要让左边缘落在 x，控件位置得写成 x + REGION_W/2。
--
-- 宽度给得比任何一行文字都宽，就不会触发截断/裁剪；wordwrap 默认关闭，
-- 也不会换行。这样文字内容后面再改（季节行、配比值）也不用重算位置。
local TEXT_REGION_W = 4000

local function AddText(parent, x, y, str, size, colour, align)
    local sz = size or 14
    local t = parent:AddChild(Text(FONT, sz, str or ""))
    t:SetRegionSize(TEXT_REGION_W, sz * 2)
    t:SetVAlign(ANCHOR_MIDDLE)
    t:SetHAlign(align or ANCHOR_LEFT)
    -- 居中对齐时 region 中心就是 x，不需要那半个 region 的偏移
    t:SetPosition((align == ANCHOR_MIDDLE) and x or (x + TEXT_REGION_W * 0.5), y, 0)
    if colour ~= nil then
        t:SetColour(colour[1], colour[2], colour[3], 1)
    end
    return t
end

-- 洋葱和番茄的「作物图标」要换名字。
-- 原版的 onion.tex / tomato.tex **根本不在 inventoryimages1~4.xml 里**，
-- 而 GetInventoryItemAtlas 只搜这四个（simutil.lua:670-680，不搜 inventoryimages.xml），
-- 游戏把它们换成了 quagmire 那套（在 inventoryimages3.xml）。
-- 不换的话这两行的作物图标会取不到、直接空着。
-- 种子不用换 —— "xxx_seeds.tex" 两个名字都在图集里。
local ICON_REMAP = {
    onion  = "quagmire_onion",
    tomato = "quagmire_tomato",
    -- 催长剂瓶：prefab 名带下划线（soil_amender），库存输入里用短名
    soilamender = "soil_amender",
}

local function IconTexName(id, suffix)
    if suffix == ".tex" and ICON_REMAP[id] ~= nil then
        return ICON_REMAP[id] .. suffix
    end
    return id .. suffix
end

-- 取一个物品的图标贴到 parent 上，返回这个 Image；取不到就返回 nil（不画）。
--
-- 图标不用自己做 —— 游戏物品图集里就有。GetInventoryItemAtlas()
-- （定义在 scripts/simutil.lua，是全局函数）拿贴图名去
-- images/inventoryimages1~4.xml 里搜，返回包含它的那个图集路径，搜不到返回 nil。
-- 游戏自己的植物登记表（widgets/redux/farmplantpage.lua）就是这么取图的。
--
-- 全程 pcall + 判空：Image() 的参数不对能把游戏直接带崩，而少一个图标
-- 完全不值得让游戏挂掉 —— 取不到就干脆不画。
local icon_warned = false

local function AddItemIcon(parent, id, suffix, x, y, size)
    local tex = IconTexName(id, suffix)

    local ok, atlas = pcall(GetInventoryItemAtlas, tex, true)
    if not ok or atlas == nil then
        if not icon_warned then
            icon_warned = true
            print("[FarmHelper] 物品图集里找不到 " .. tex .. "，这一项不画图标")
        end
        return nil
    end

    local ok2, img = pcall(function()
        local i = parent:AddChild(Image(atlas, tex))
        i:ScaleToSize(size, size)
        i:SetPosition(x, y, 0)
        return i
    end)
    if not ok2 or img == nil then
        if not icon_warned then
            icon_warned = true
            print("[FarmHelper] 图标创建失败：" .. tex .. " @ " .. tostring(atlas))
        end
        return nil
    end
    return img
end

-- 一个能点的小按钮。
--
-- ★★ v1.8.1 重写。之前是自己算坐标做矩形命中（「DST 没有现成按钮」—— 这个判断是错的）。
--    正确做法是用 TEMPLATES.InvisibleButton：它是 ImageButton 的透明封装，
--    点击由 DST 的**焦点系统**处理（Button:OnControl 里判断 self.focus），
--    不需要我们碰任何坐标。游戏内 HUD 里大量这么用：
--    widgets/worldresettimer.lua、demotimer.lua、redux/plantregistrywidget.lua 等。
--
--    自己算坐标的版本在实机上点不动 —— 鼠标坐标和 Widget:GetWorldPosition()
--    的换算和引擎焦点系统给出的结果对不上，而且这种错**不报错、只是没反应**。
--
--    视觉效果仍然是自绘的（半透明底 + 文字），InvisibleButton 只负责收点击。
--
-- ★ v2.0.1：InvisibleButton 的命中区域必须显式钉死，详见函数里那段说明。
--   不改的话鼠标一悬停命中区域就会放大几十倍，点到下一行的按钮上。

-- 点击诊断的剩余条数（只打前几次，别刷屏）
local BTN_CLICK_DIAG = 8

-- 建一块「只收事件、看不见」的命中区域，交给 DST 的焦点系统托管。
-- 返回节点，拿不到就返回 nil（调用方要有降级方案）。
--
-- 全程 pcall：模板或素材万一有问题，最坏也只是「点不动」，
-- 不能让整个面板构造失败（主菜单那次崩栈的教训）。
--
-- ★★★ v2.0.1 关键修复：InvisibleButton 把「像素尺寸」当成缩放倍数用了。
--
--   templates.lua:858-867 的实现是：
--     local btn = ImageButton(..., {width,height}, {0,0})
--     btn:SetFocusScale(width, height)
--     btn:SetNormalScale(width, height)
--
--   而 SetNormalScale / SetFocusScale 是**缩放倍数**，不是尺寸 ——
--   它们内部是 self.image:SetScale()（imagebutton.lua:283-305）。
--   更要命的是 OnGainFocus 的最后一步还会再 SetScale(focus_scale) 一次
--   （imagebutton.lua:127-129）。
--
--   后果：鼠标**一悬停**，这个 48px 的按钮命中区域就被放大成 48 倍，
--   上下好几行全被它盖住。焦点系统选中「最上层」那个 —— 也就是
--   **下一行**的按钮。表现就是：点胡萝卜的 +，数字加到了洋葱头上。
--
--   修法：把缩放倍数压回 1，改用 ImageButton:ForceImageSize()
--   把命中区域**显式钉成** w × h（imagebutton.lua:37-41，内部是 ScaleToSize，
--   算的是目标像素尺寸，不受贴图自然尺寸影响）。
--   再开 ignore_standard_scaling，让 OnGainFocus 走 ScaleToSize 那条分支。
local function MakeHit(parent, w, h, onclick)
    local ok, TEMPLATES = pcall(require, "widgets/templates")
    if not ok or TEMPLATES == nil or TEMPLATES.InvisibleButton == nil then
        return nil
    end

    local ok2, node = pcall(TEMPLATES.InvisibleButton, w, h, onclick)
    if not ok2 or node == nil then
        return nil
    end

    local hit = parent:AddChild(node)
    hit:SetPosition(0, 0, 0)

    if node.ForceImageSize ~= nil then
        node.ignore_standard_scaling = true
        node:SetFocusScale(1, 1, 1)
        node:SetNormalScale(1, 1, 1)
        node:ForceImageSize(w, h)      -- ★ 必须放在这三个之后
    end

    -- 按下时整个按钮会下移 3px（Button.clickoffset + move_on_click），
    -- 焦点可能因此跑掉、点击就丢了。关掉这个位移。
    node.move_on_click = false

    if hit.SetClickable ~= nil then
        hit:SetClickable(true)
    end
    return hit
end

local function AddButton(parent, x, y, w, h, label, onclick, size)
    local btn = parent:AddChild(Widget("btn"))
    btn:SetPosition(x, y, 0)

    local bg = btn:AddChild(Image("images/global.xml", "square.tex"))
    bg:SetSize(w, h)
    bg:SetPosition(0, 0, 0)
    bg:SetTint(1, 1, 1, BUTTON_ALPHA)

    local t = btn:AddChild(Text(FONT, size or 26, label))
    t:SetPosition(0, 0, 0)
    t:SetColour(0.93, 0.91, 0.85, 1)
    btn.label_text = t    -- 开关型按钮改字用

    local hit = MakeHit(btn, w, h, onclick)
    if hit ~= nil then
        -- 点击诊断：只打前几次，确认「点到的到底是哪一个」。
        -- 下次再出现「点 A 加到 B」，一眼就能分清是命中错还是 cid 错。
        local wrapped = onclick
        if wrapped ~= nil then
            -- 重新 SetOnClick 一次，把诊断包在外面（会覆盖 InvisibleButton 设的那个）
            hit:SetOnClick(function()
                if BTN_CLICK_DIAG > 0 then
                    BTN_CLICK_DIAG = BTN_CLICK_DIAG - 1
                    print(string.format(
                        "[FarmHelper] 点击 · 「%s」 @ (%.0f, %.0f) 尺寸 %.0fx%.0f",
                        tostring(label), x, y, w, h))
                end
                wrapped()
            end)
        end

        -- 悬停高亮：Button:OnGainFocus / OnLoseFocus 会回调这两个字段。
        -- 分页标签还要照顾「当前页」的底色，别把高亮盖掉。
        local function base_alpha() return btn.tab_on and TAB_ALPHA_ON or BUTTON_ALPHA end
        hit.ongainfocus = function() bg:SetTint(1, 1, 1, BUTTON_ALPHA_HOVER) end
        hit.onlosefocus = function() bg:SetTint(1, 1, 1, base_alpha()) end
    end

    if hit == nil then
        print("[FarmHelper] 警告：拿不到 TEMPLATES.InvisibleButton，按钮将无法点击")
    end

    btn.hit      = hit
    btn.bg       = bg
    btn.hit_w    = w
    btn.hit_h    = h
    btn.origin_x = x        -- 面板内坐标，只给 IsOverAnyButton 当后备用
    btn.origin_y = y
    btn.onclick  = onclick
    return btn
end

-- 示意图里每种作物的代表色（图例用的是同一套）
local CROP_COLOUR = {
    carrot      = { 1.00, 0.62, 0.26 },   -- 橙
    pumpkin     = { 0.96, 0.48, 0.16 },   -- 深橙
    onion       = { 0.92, 0.78, 0.88 },   -- 粉白
    pomegranate = { 0.86, 0.26, 0.36 },   -- 石榴红
    corn        = { 0.98, 0.86, 0.32 },   -- 玉米黄
    asparagus   = { 0.56, 0.86, 0.34 },   -- 浅绿
    garlic      = { 0.94, 0.94, 0.88 },   -- 蒜白
    durian      = { 0.76, 0.82, 0.36 },   -- 黄绿
    potato      = { 0.82, 0.66, 0.46 },   -- 土褐
    eggplant    = { 0.62, 0.42, 0.82 },   -- 紫
    dragonfruit = { 0.96, 0.42, 0.66 },   -- 玫红
    pepper      = { 0.90, 0.26, 0.22 },   -- 正红
    tomato      = { 0.96, 0.36, 0.26 },   -- 番茄红
    watermelon  = { 0.36, 0.76, 0.46 },   -- 西瓜绿
}

local function CropColour(id)
    return CROP_COLOUR[id] or { 0.70, 0.70, 0.70 }
end

-- 取游戏自带的本地化名字，取不到就退回英文 id，保证不会显示空白
local function PlantName(id)
    local s = STRINGS.NAMES[string.upper(id)]
    return (s ~= nil and s ~= "") and s or id
end

local function SeedName(id)
    local key = string.upper(id) .. "_SEEDS"
    local s = STRINGS.NAMES[key]
    return (s ~= nil and s ~= "") and s or (id .. "_seeds")
end

-- 三种养分的名字也直接取游戏自己的本地化字符串：
-- 中文版会显示「催长剂 / 堆肥 / 粪肥」，切英文也自动跟着变。
local NUTRIENT_FALLBACK = { "催长剂", "堆肥", "粪肥" }
local function NutrientName(i)
    local ui = STRINGS.UI
    local registry = ui ~= nil and ui.PLANTREGISTRY or nil
    local tbl = registry ~= nil and registry.NUTRIENTS or nil
    local s = tbl ~= nil and tbl["NUTRIENT_" .. i] or nil
    if s ~= nil and s ~= "" then
        return s
    end
    return NUTRIENT_FALLBACK[i]
end

-- 读当前季节。在主菜单等还没有世界的情况下返回 nil，避免报错。
local function GetSeason()
    if TheWorld == nil or TheWorld.state == nil then
        return nil, nil
    end
    return TheWorld.state.season, TheWorld.state.remainingdaysinseason
end

-- modinfo 里存的是按键的 keycode，这里换回能给人看的字母
local KEY_LABEL = {
    [104] = "H", [106] = "J", [107] = "K", [108] = "L",
    [110] = "N", [98] = "B", [121] = "Y",
}
local KEY_HINT  = KEY_LABEL[OPEN_KEY] or "快捷键"
local PAGE_HINT = KEY_LABEL[PAGE_KEY] or "切页键"

--==============================================================================
--  四、当前季节的平衡配比
--
--  一株作物对三种养分的净影响是确定的。机制在
--  components/farming_manager.lua 的 CycleNutrientsAtPoint()：
--
--    · 先扣掉它标出的消耗点数
--    · 再把「实际消耗总量」平分给它不消耗的那几项
--      （farm_plant_defs.lua: 不消耗 ⇔ nutrient_consumption[i] == 0）
--
--  所以每株作物的净变化三项之和恒为 0 —— 它只是把养分从一种换成了另一种。
--  于是只要让三组作物「消耗掉的总点数」彼此相等，整块地的养分就会一直不变。
--==============================================================================

-- ★ 前向声明：轮作算法（SimulateChain / FindChains）定义在下面「轮作」那一段，
--   但第一页的 RefreshPlan 也要拿它算「本季种法」。
--   Lua 的 local 走词法作用域 —— 定义在后面的 local，前面的函数根本看不见
--   （会被当成全局变量取到 nil），所以这里先把名字占下来。
local FindChains
local FindUnitPlan      -- v2.6.0：每块地皮的零和配比。定义在 CropById 之后（词法作用域）

-- ★★★ v2.6.10 修实机崩溃：`UnitPlans` / `TileFamilyCount` 定义在 1500+ 行，
--   而 `RefreshPlan` 在 1367 行就调用了它们 —— Lua 的词法作用域下，
--   后定义的 local 对前面的函数**不可见**，会被当成全局变量取到 nil。
--   表现是进游戏直接弹「attempt to call global 'UnitPlans' (a nil value)」。
--   （`FindChains` / `FindUnitPlan` 当初前置声明过，所以没事；
--     这两个是 v2.6.9 新加的，忘了同样处理。）
local UnitPlans         -- v2.6.9：前 N 个方案（面板列主方案 + 备选用）
local TileFamilyCount   -- v2.6.9：家族逐株判定（第一页图标注也要用）

-- 一株作物的养分净变化 { 催长剂, 堆肥, 粪肥 }
local function NetDelta(consume)
    local total = consume[1] + consume[2] + consume[3]

    local zeros = 0
    for i = 1, 3 do
        if consume[i] == 0 then
            zeros = zeros + 1
        end
    end

    local d = { 0, 0, 0 }
    for i = 1, 3 do
        if consume[i] > 0 then
            d[i] = -consume[i]
        elseif zeros > 0 then
            d[i] = total / zeros
        end
    end
    return d
end

local function Gcd(a, b)
    while b ~= 0 do
        a, b = b, a % b
    end
    return a
end

-- 在 items（{ id, size }）里凑出总规模 target，株数尽可能少。
-- 同一种作物可以重复种，所以是完全背包。
local function SolveGroup(items, target)
    local INF = 1000000
    local dp, pick = {}, {}
    for s = 0, target do
        dp[s] = INF
    end
    dp[0] = 0

    for s = 0, target do
        if dp[s] < INF then
            for idx = 1, #items do
                local ns = s + items[idx].size
                if ns <= target and dp[s] + 1 < dp[ns] then
                    dp[ns] = dp[s] + 1
                    pick[ns] = { idx = idx, prev = s }
                end
            end
        end
    end

    if dp[target] >= INF then
        return nil
    end

    -- 回溯出每种作物要几株
    local counts = {}
    local s = target
    while s > 0 do
        local p = pick[s]
        if p == nil then
            return nil
        end
        counts[p.idx] = (counts[p.idx] or 0) + 1
        s = p.prev
    end
    return counts
end

-- 算当前季节的配比。返回 { { id = "carrot", n = 1 }, ... }；算不出来返回 nil。
local function BuildSeasonPlan(season)
    if season == nil then
        return nil
    end

    -- 只收「恰好消耗一种养分」的作物：它们各自归到一个轴上，规则干净、也好执行。
    -- 番茄 (2,2,0) 和西瓜 (0,2,2) 同时吃两种养分，方向不是单一的，不参与。
    local groups = { {}, {}, {} }
    for _, crop in ipairs(CROPS) do
        if crop.seasons[season] then
            local d = NetDelta(crop.consume)

            local negs, axis, size = 0, nil, nil
            for i = 1, 3 do
                if d[i] < 0 then
                    negs = negs + 1
                    axis = i
                    size = -d[i]
                end
            end

            if negs == 1 then
                table.insert(groups[axis], {
                    id = crop.id,
                    size = math.floor(size + 0.5),
                })
            end
        end
    end

    -- 三组都得有作物，缺一组这个季节就配不平
    local step = { 0, 0, 0 }
    for i = 1, 3 do
        if #groups[i] == 0 then
            return nil
        end
        local g = 0
        for _, it in ipairs(groups[i]) do
            g = Gcd(g, it.size)
        end
        step[i] = g
    end

    -- 每组只能凑出自己「最大公约数」的倍数，所以取三者最小公倍数 ——
    -- 这就是能配平的最小种植规模（一般是 1:1:1）。
    local target = 1
    for i = 1, 3 do
        target = target * step[i] / Gcd(target, step[i])
    end
    target = math.floor(target + 0.5)

    local plan = {}
    for i = 1, 3 do
        local counts = SolveGroup(groups[i], target)
        if counts == nil then
            return nil
        end
        for idx = 1, #groups[i] do
            if counts[idx] ~= nil then
                table.insert(plan, { id = groups[i][idx].id, n = counts[idx] })
            end
        end
    end
    return plan
end

--==============================================================================
--  五、面板位置：拖动 + 本地存档
--==============================================================================

-- ★ v2.0.1：标题栏高度从 36 提到 48。
--   以前是 36，可标题字号是 38 —— **标题比它的容器还高**，
--   38 号字按 VAlign MIDDLE 摆在 y=-26 时要占 -7 ~ -45，
--   而标题栏只到 -36，下面一截露在条外面。
--   这就是用户说的「农事两个字不在那个框里」（纵向溢出，不是横向）。
--   现在 48 > 38，整个标题稳稳落在条内；顺带手柄也更好抓。
local GRIP_H   = 48             -- 标题栏高度，也就是「抓住这里能拖」的纵向范围
local POS_FILE = "farmhelper_pos"
-- ★ v1.8.0 起不再有 KEEP（「四边各留 N 像素」那种松钳制）——
--   它会让面板被拖到几乎全部出屏，而且那个位置还会被存档记下来。
--   现在 MoveTo 的要求是「整个面板留在屏幕里」，见下面的实现。

-- 默认位置：屏幕左上角。
-- ★ v2.0.0：先量了屏幕（client_log 里 1920×1080），面板 1010×1025 放得下，
--   所以 y 留 12 就够。MoveTo 里还有一层兜底钳制（放得下就整个推进屏幕内）。
local HOME_X, HOME_Y = 20, -12

-- 读盘是异步回调（GetPersistentString 不会马上返回），
-- 所以用一个模块级的表把结果交接给面板。
local POS = { requested = false, x = nil, y = nil }

local function RequestSavedPos()
    if POS.requested then
        return
    end
    POS.requested = true

    TheSim:GetPersistentString(POS_FILE, function(load_success, data)
        if load_success and type(data) == "string" then
            local sx, sy = data:match("^(%-?%d+%.?%d*),(%-?%d+%.?%d*)$")
            if sx ~= nil and sy ~= nil then
                POS.x, POS.y = tonumber(sx), tonumber(sy)
            end
        end
    end)
end

local function SavePos(x, y)
    TheSim:SetPersistentString(POS_FILE, string.format("%.1f,%.1f", x, y), false)
end

-- 拖动过程中的临时状态。放在模块级，因为鼠标回调不在面板的方法里。
local DRAG = { active = false, mx = 0, my = 0, px = 0, py = 0, latched = false }

-- 拖动诊断的剩余条数（只打前几次，别刷屏）
local DRAG_DIAG_LEFT = 8

--==============================================================================
--  六、面板本体
--==============================================================================

local FarmHelperPanel = Class(Widget, function(self, owner)
    Widget._ctor(self, "FarmHelperPanel")

    self.owner = owner

    -- 面板左上角在父容器里的位置。这里自己存一份，不去读 GetPosition()，
    -- 免得受锚点换算影响；拖动全程以它为准。
    self.panel_x, self.panel_y = HOME_X, HOME_Y

    -- 贴住屏幕左上角
    self:SetHAnchor(ANCHOR_LEFT)
    self:SetVAnchor(ANCHOR_TOP)
    self:SetPosition(self.panel_x, self.panel_y, 0)

    -- 半透明底板
    local bg = self:AddChild(Image("images/global.xml", "square.tex"))
    bg:SetSize(PANEL_W, PANEL_H)
    bg:SetPosition(PANEL_W * 0.5, -PANEL_H * 0.5, 0)
    bg:SetTint(0.04, 0.04, 0.05, 0.86)

    -- 三页的内容各放一个容器，切页时整块 Show/Hide
    -- ★ v2.5.0 加第三页「轮作」：前两页只能算出「这一茬种几个」，
    --   而养分是每格单独记账的，总和配平救不了单格漂移 —— 轮作页负责解决这个。
    self.page1 = self:AddChild(Widget("page1"))
    self.page1:SetPosition(0, 0, 0)
    self.page2 = self:AddChild(Widget("page2"))
    self.page2:SetPosition(0, 0, 0)
    self.page3 = self:AddChild(Widget("page3"))
    self.page3:SetPosition(0, 0, 0)

    -- 标题栏。这块是拖动手柄，比底板亮一点，让人看得出能抓。
    self.grip_bg = self:AddChild(Image("images/global.xml", "square.tex"))
    self.grip_bg:SetSize(PANEL_W, GRIP_H)
    self.grip_bg:SetPosition(PANEL_W * 0.5, -GRIP_H * 0.5, 0)
    self.grip_bg:SetTint(1, 1, 1, 0.06)

    -- ★★ v2.1.0：拖动手柄的命中判定也交给引擎的焦点系统，不再自己换算屏幕坐标。
    --   原来的做法是拿 TheInput:GetScreenPosition() 和 Widget:GetWorldPosition()
    --   对减 —— 这两个到底是不是同一套、有没有算上锚点，从 mod 这边没法验证，
    --   一旦对不上就是「按下没反应」，而且**不报错**。
    --   InvisibleButton 是引擎自己判定的，坐标永远和它对得上。
    --   ★ 必须在分页按钮**之前**加：后加的子节点盖在上面，鼠标压在按钮上时
    --     焦点归按钮，手柄就不会抢（否则点按钮会顺带把面板拖走）。
    self.grip_hit = MakeHit(self, PANEL_W, GRIP_H, nil)
    if self.grip_hit ~= nil then
        self.grip_hit:SetPosition(PANEL_W * 0.5, -GRIP_H * 0.5, 0)
    else
        print("[FarmHelper] 警告：拿不到 InvisibleButton，拖动退回坐标判定（可能不准）")
    end

    -- 标题行（整条标题栏都是拖动手柄）
    -- ★ y 用 -26：36 号字占 -8 ~ -44，标题栏是 0 ~ -48，上下都留得住。
    AddText(self, PAD, -26, "农事手册", 36, C.title)
    AddText(self, 210, -26, "拖动这里", 22, C.dim)
    -- 版本号：mods.lua:427 把 modinfo 表整个注入了 modmain 环境（env.modinfo），
    -- 这里直接读 modinfo.version，以后只改 modinfo 一处，面板跟着走。
    -- 摆在 322：「拖动这里」4 字 ×22 ≈ 101px，占 210~311；「v2.4.0」20 号 ≈ 66px，
    -- 占 322~388，离分页按钮（450 起）还有 60px 余量。
    AddText(self, 322, -26,
        "v" .. tostring((type(modinfo) == "table" and modinfo.version) or "?"), 20, C.dim)
    -- 按键提示。切页用键盘（比点按钮可靠），按钮只是顺手留着。
    AddText(self, 780, -26,
        KEY_HINT .. " 开关 / " .. PAGE_HINT .. " 切页", 22, C.dim)

    -- 季节行（这一行会随游戏时间刷新）
    self.season_text = AddText(self.page1, PAD, -104, "", 32, C.now)

    -- 当前季节的平衡配比。也是随季节刷新的。
    -- ★ v2.0.0：配比值从「和标签并排」改成**单独占一行**。
    --   布局图放大挪到右上角之后，并排那点宽度只剩不到 450px，
    --   放不下「胡萝卜 4 株 : 玉米 4 株 : 土豆 4 株」（28 号字约 560px），会撞上去。
    --   挪下来一行，左边整条 590px 都归它。
    -- ★★★ v2.6.3：这一块就是**四季推荐作物** —— 面板最主要的信息。
    --   v2.5.x 这个位置放的是「本季种法（轮作链）」，轮作已不做主推
    --   （灰机 wiki 也评价它「起效不明显且慢」），腾出来给四季速查。
    --
    --   下面的配比全部来自整季模拟（`_sim.py`：好季节、水分满足、每阶段照料）：
    --     秋/春  4 番茄 + 4 土豆（1 块 8 株，7 茬，100% 巨大）
    --     夏     6 番茄 + 3 火龙果（2 块，火龙果贴地皮边界）
    --     冬     3 南瓜 + 3 芦笋 + 3 土豆（2 块，三种各占一列贴边界）
    --   四季跑下来家族 / 养分 / 拥挤三个压力源次数全是 0，水位每茬回到同一组数字。
    AddText(self.page1, PAD, -146, "四季推荐（每块地皮最多 9 株）", 26, C.head)

    -- 四行数据，当前季节会高亮（刷新在 RefreshPlan 里）
    self.season_row = {}
    for i, s in ipairs(SEASON_ORDER) do
        -- 24 号字：最长那行「冬　3 南瓜 + 3 芦笋 + 3 土豆　2 块」实测 404px，
        -- 右边缘 426，离右上角那块地皮图（630 起）还有 204px 余量（_layout.py 核对）。
        self.season_row[s] = AddText(self.page1, PAD, -186 - (i - 1) * 34,
            "", 24, C.text)
    end
    AddText(self.page1, PAD, -326,
        "同种挤一堆、每堆至少 4 株；标 2 块的让少的那种贴地皮边界", 19, C.dim)
    AddText(self.page1, PAD, -348,
        "图下标橙色的，是家族真算下来凑不满的（照着种出不了巨大）", 19, C.warn)

    -- 种植布局（v2.6.9）：本季摆法 —— 并排画前几个方案（主方案 + 备选）。
    --   图随季节重建。原来图右边那 4 行短说明（同种挤一堆 / 每堆 4 株 / …）
    --   已经并进下面 -326 的那一行里了，这里腾出来给第 2、3 个方案。
    -- 标题必须放在图框**上方**（图框顶 -95，株点从 -109 起）——
    -- 放 -112 会压到第一行株点上（_layout.py 抓到过 6 处重叠）。
    AddText(self.page1, 485, -70, "本季摆法（前面的优先）", 24, C.head)

    self.layout_one_root = self.page1:AddChild(Widget("layout_one_root"))
    self.layout_one_root:SetPosition(0, 0, 0)

    -- 三列养分显示的是「净变化」，不是单纯的消耗量 ——
    -- 作物每长一个阶段，吃掉某些养分的同时会把等量的还给「它不消耗」的另几种，
    -- 所以一格里有正有负才是完整的一笔账。先把这个规则写在表头上面。
    -- ★ v2.0.0：拆成两行。原来一整句 40 个字，24 号字要约 1100px，
    --   面板才 1010 宽，末尾会被挤出底板外。
    AddText(self.page1, PAD, -372, "每格 = 净变化：负 = 消耗，正 = 产出", 23, C.title)
    AddText(self.page1, PAD, -404, "吃掉的等量还给「不消耗」的另两种", 23, C.title)

    -- 表头
    AddText(self.page1, COL.name,   -446, "作物名",             28, C.head)
    AddText(self.page1, COL.seed,   -446, "种子名",             28, C.head)
    AddText(self.page1, COL.n1,     -446, NutrientName(1),      28, C.nutrient[1])
    AddText(self.page1, COL.n2,     -446, NutrientName(2),      28, C.nutrient[2])
    AddText(self.page1, COL.n3,     -446, NutrientName(3),      28, C.nutrient[3])
    AddText(self.page1, COL.season, -446, "适宜季节",           28, C.head)

    -- 数据行的容器。季节一变就整个重建，比逐个改颜色省事。
    self.rows_root = self.page1:AddChild(Widget("rows_root"))
    self.rows_root:SetPosition(0, 0, 0)

    -- 底部说明。
    -- ★ 只留最要紧的一条：配比成立的前提，以及唯一能打破它的东西。
    --   详细推导和完整规则在 README 里，面板上放多了会挤掉表格的字号。
    --   两个依据：消耗量会被钳到当前存量（farming_manager.lua:414），
    --   所以土壤见底时「归还」也跟着缩水，循环启动不起来；
    --   杂草是 weed_plants.lua:43 调 CycleNutrientsAtPoint(..., nil)，
    --   restore 传 nil —— 只吃不还，weed_defs.lua:56-59 里四种杂草都是各 2 点。
    -- ★ v2.6.0（排版修正）：原来是 -972 配 23 号字 —— 字顶边 -960.5 反而**钻进**
    --   表格最后一行（底边 -945）里 15.5px，`_layout.py` 的手工核对项把它报了出来。
    --   两处收一收：字号 23 → 21（顶边从 -960.5 升到 -961.6 还不够），
    --   再整体下移到 -982 —— 顶边 -970.6，与末行底边 -945 留 25.6px。
    --   末行底边 -983.5，底板（PANEL_H 1040）在 -1020，还剩 36.5px。
    AddText(self.page1, PAD, -982,
        "养分要有存量，循环才启动得起来；杂草只吃不还（各 2 点），会长草就先拔。",
        21, C.warn)

    -- ★ v2.4.4 轮作提示（用户实机反馈"照配平种会缺肥"暴露的机制盲区）：
    --   养分账本是**每格独立**的（farming_manager.lua:400-455，消耗和归还
    --   都在作物自己那一格结算），配平只保证全图总和归零。
    --   单一格永远单向漂移：胡萝卜格每阶段催 -4 —— 一两茬后枯竭。
    --   解法只有轮作（下茬同格换互补作物）或备腐烂物随手补。
    -- ★ v2.5.2：起点 PAD → 79，补上光标 x=60（不设 region 时文字以 x 为中心展开，
    --   左边缘会偏左半个字宽，PAD=22 时够不到 60）。
    AddText(self.page1, 79, -1008,
        "养分按格结算：配平只是总和归零，同格连种会单向漂移；换茬轮作请见第三页。",
        21, C.note)

    --==========================================================================
    -- 第二页：自己选种子、选地皮形状，看图怎么摆
    --==========================================================================

    self.seed_counts    = {}          -- 作物 id -> 用户填的可用量（配平不会改它）
    self.plan_counts    = nil         -- 一键配平的建议结果；nil = 手动模式
    -- ★ v2.6.8：tile_mode 整个删了 —— 地皮数现在由算法按「每种凑够 4 株要几块」定。
    self.cur_page       = 1
    self.buttons        = { {}, {}, {} }  -- 每页的按钮，命中检测用（v2.5.0 三页）
    self.mouse_was_down = false

    -- ★ v2.6.7：配平器的输入只剩「考虑家族」一个开关。
    --   原来还有一块肥料库存（按物品选、折算成三类点数）—— 已删，理由见 FERT_ITEMS 处。
    self.family_mode = false

    AddText(self.page2, PAD, -92,
        "填上你手里的作物数量，点「一键配平」，算每块地皮的零和配比：", 24, C.note)

    -- ★ v2.4.2 时令颜色图例（用户反馈：不知道绿/橙/白/暗什么意思）
    AddText(self.page2, PAD, -122,
        "时令：绿=当季(无压力长得快)；橙=当季不喜(吃压力)；白=它喜欢的季节；暗=无关",
        18, C.dim)

    -- ★ v2.6.7：这里原来是「12 种肥料库存输入网格 + 折算行」，整块删掉。
    --   它没有任何下游读者（详见 FERT_ITEMS 处的注释）。腾出来的位置放三行
    --   「怎么照着种」—— 比一个填了也不起作用的输入框有用。
    AddText(self.page2, PAD, -150,
        "一块地皮最多 9 株（锄满就是 3×3 九宫格）。", 22, C.text)
    AddText(self.page2, PAD, -180,
        "配比是「每块地皮自己收支相抵」—— 照着种就不用施肥。", 22, C.text)
    AddText(self.page2, PAD, -210,
        "同种至少 4 株挤一堆；凑不满 4 株的那种，贴地皮边界跟隔壁块凑。", 22, C.note)

    -- 家族开关 + 一键配平
    local fbtn = AddButton(self.page2, 170, -290, 240, 40, "考虑家族：关",
        function() self:ToggleFamily() end, 24)
    table.insert(self.buttons[2], fbtn)
    self.family_btn = fbtn
    local bal = AddButton(self.page2, 430, -290, 170, 40, "一键配平",
        function() self:AutoBalance() end, 24)
    table.insert(self.buttons[2], bal)
    AddText(self.page2, 530, -290, "省料优先：催长剂 > 堆肥 ≈ 粪肥", 20, C.dim)

    -- 14 种作物，两列（每列 7 行）。
    -- 一行的构成：图标 · 作物名 · 时令四字 · [−] · 数量 · [+]
    -- ★ v2.4.2：时令字 15 → 20（用户嫌小）、字距 20 → 26；行距 48 → 46
    --   腾出顶部提醒行。命中区域仍是 ForceImageSize 钉死的精确尺寸，不会串。
    self.seed_texts = {}
    self.season_badges = {}
    for i, crop in ipairs(CROPS) do
        local col  = (i - 1) % 2
        local rowi = math.floor((i - 1) / 2)
        local cx   = (col == 0) and 60 or 560
        -- ★ v2.5.1：首行 -330 → -338。作物名上挪了 11px，原来的起点会让
        --   第一行的作物名顶到「家族开关」按钮的底边（-310）上，下移 8px 让开。
        local cy   = -338 - rowi * 46

        -- ★ v2.5.1：一行拆成上下两条，各带自己的图标 ——
        --   上行「作物图标 · 作物名」，下行「种子图标 · 种子名」。
        --   手里拿的是种子，只写「番茄」对着背包认不出是哪颗，所以种子那行
        --   连名字带图标一起给。
        --
        --   两个图标是**斜着错开**的（作物 32 在上行、种子 22 在下行，x 也错开）：
        --   行距只有 46，上下叠放两个图标要 54，塞不下；错开之后它们的 x 不重叠，
        --   就算 y 有交叠也不会压在一起（排版脚本按矩形求交，已验过 0 重叠）。
        --   作物图标 x 0~32 / y cy-5~cy+27，种子图标 x 39~61 / y cy-22~cy，
        --   同列的相邻行之间：作物↔作物、种子↔种子各留 14px / 24px，
        --   作物↔邻行种子 x 不相交，都不碰。
        AddItemIcon(self.page2, crop.id, ".tex", cx + 16, cy + 11, 32)
        AddItemIcon(self.page2, crop.id, "_seeds.tex", cx + 50, cy - 11, 22)

        -- 名字起点 68：让开种子图标（到 61），两行左对齐成一条线。
        -- 作物名 22 号（3 字 ≈ 76px，占 68~144）；种子名 17 号
        -- （最长 6 字「随风飘的种子」≈ 117px，占 68~185）—— 种子名在下层，
        -- 时令字也在上行，两者 y 不相交，所以种子名可以一直排到 185 不打架。
        AddText(self.page2, cx + 68, cy + 11, PlantName(crop.id), 22, C.text)
        AddText(self.page2, cx + 68, cy - 11, SeedName(crop.id), 17, C.seed)

        -- ★ v2.2.0 季节时令：每个作物名后面跟「春夏秋冬」四个字。
        --   颜色四档（RefreshSeasonBadges 统一刷）：
        --   当季且喜欢 = 绿（不因季节加压，生长减半）、当季但不喜欢 = 橙（提醒），
        --   非当季但喜欢 = 白（提示以后种）、其他 = 暗。
        -- ★ v2.5.1：跟着作物名挪到上行（y = cy + 11），字距 23、起点 150
        --   （占 150~242，离 − 按钮左边缘 246 还有 4px）。
        local badges = {}
        for si, sname in ipairs(SEASON_ORDER) do
            table.insert(badges,
                AddText(self.page2, cx + 150 + (si - 1) * 23, cy + 11,
                    SEASON_CN[sname], 20, C.dim))
        end
        self.season_badges[crop.id] = badges

        -- 先把 id 固定到局部变量再进闭包，别直接捕 crop.id ——
        -- 循环变量的 upvalue 可能被所有闭包共享，那样每个 + 都会改到最后一种作物。
        local cid = crop.id
        local minus = AddButton(self.page2, cx + 266, cy, 40, 40, "-",
            function() self:AdjustSeed(cid, -1) end, 26)
        local plus  = AddButton(self.page2, cx + 402, cy, 40, 40, "+",
            function() self:AdjustSeed(cid, 1) end, 26)
        table.insert(self.buttons[2], minus)
        table.insert(self.buttons[2], plus)

        -- 数量居中在 − 和 + 之间。走 align 参数，别在 AddText 之后自己改
        -- HAlign —— region 已经设好了，事后再改对齐不会连带改位置，会直接跑偏。
        local num = AddText(self.page2, cx + 334, cy, "0", 24, C.title, ANCHOR_MIDDLE)
        self.seed_texts[crop.id] = num
    end

    -- ★ v2.6.8：删掉「地皮形状：3x3 / 3x3 x2」两个按钮。
    --   算法换成「每块地皮的零和配比」之后就不读 tile_mode 了，可按钮还留着 ——
    --   点它只会重画一遍，画出「一块满、另一块永远空着」的假象（因为布局只有一块的量），
    --   而诊断行却写着「×2 块」。现在地皮数由算法定（diag.blocks），图按它画。

    -- 示意图 + 图例 + 诊断（内容随选择重建，放在这三个容器里）
    AddText(self.page2, PAD, -716, "这样摆：", 26, C.head)
    self.demo_root   = self.page2:AddChild(Widget("demo_root"))
    self.demo_root:SetPosition(0, 0, 0)
    self.legend_root = self.page2:AddChild(Widget("legend_root"))
    self.legend_root:SetPosition(0, 0, 0)
    self.diag_root   = self.page2:AddChild(Widget("diag_root"))
    self.diag_root:SetPosition(0, 0, 0)

    --══════════════════════════════════════════════════════════════════════
    --  第三页：轮作（v2.5.0）
    --
    --  这一页解决的问题跟第二页不一样：第二页算的是「这一茬种几个」，
    --  这里算的是「同一格按什么顺序换茬」。养分是每格一本账，
    --  只有让每格自己的前后茬抵消，地才不会越种越薄。
    --══════════════════════════════════════════════════════════════════════
    AddText(self.page3, PAD, -92,
        "配平只让整块地「加起来」是 0，可养分是每格单独记账的 ——", 24, C.note)
    AddText(self.page3, PAD, -126,
        "要让地不缺肥，得让同一格的前后茬互相抵消。挑作物，下面给轮作链：",
        22, C.warn)

    AddText(self.page3, PAD, -166, "我想种的作物（点右侧切换，默认勾当季）：", 22, C.head)

    -- 默认勾选：进游戏时是当前季节的当季作物。拿不到季节就全勾上。
    local s0 = GetSeason()
    self.rot_on     = {}   -- id -> 要不要参与
    self.rot_btn    = {}   -- id -> 按钮（改上面那两个字用）
    self.rot_season = {}   -- id -> 时令文字
    for _, c in ipairs(CROPS) do
        if s0 == nil then
            self.rot_on[c.id] = true
        else
            self.rot_on[c.id] = (c.seasons ~= nil and c.seasons[s0]) or false
        end
    end

    -- 14 种作物，两列 × 7 行。一行 = 图标 + 名字 + 时令 + 开关。
    -- 行距 44：图标 22 高的上下都不会碰到邻行（名字 24 号，占 ±12）。
    for i, crop in ipairs(CROPS) do
        local col  = (i - 1) % 2
        local rowi = math.floor((i - 1) / 2)
        local cx   = (col == 0) and 60 or 560
        local cy   = -200 - rowi * 44

        AddItemIcon(self.page3, crop.id, ".tex", cx + 18, cy, ICON)
        -- ★ v2.5.1：一样补上种子名（16 号，在下层），挑作物的时候也认得出种子。
        --   行距 44 比第二页更窄，所以名字 24 → 22、种子名压到 16：
        --   作物名 cy+11（占 cy~cy+22）、种子名 cy-11（占 cy-19~cy-3），
        --   图标 36 居中（cy±18），相邻行之间都还有 4~8px。
        AddText(self.page3, cx + 46, cy + 11, PlantName(crop.id), 22, C.text)
        AddText(self.page3, cx + 46, cy - 11, SeedName(crop.id), 16, C.seed)

        -- 先把 id 抓成局部变量再进闭包，否则所有按钮都会改到最后一种作物
        local rid = crop.id
        -- 时令跟作物名同一层，种子名在下层，两者 y 不相交
        self.rot_season[rid] = AddText(self.page3, cx + 132, cy + 11, "", 18, C.dim)

        local rb = AddButton(self.page3, cx + 320, cy, 96, 36, "不要",
            function() self:ToggleRotCrop(rid) end, 22)
        table.insert(self.buttons[3], rb)
        self.rot_btn[rid] = rb
    end

    -- ★ x=95：150 宽 → 占 20~170，左边留得住（60 会伸到底板外 15px）
    local r_s = AddButton(self.page3, 95, -510, 150, 40, "只选当季",
        function() self:PickRotCrops("season") end, 22)
    local r_a = AddButton(self.page3, 230, -510, 110, 40, "全选",
        function() self:PickRotCrops("all") end, 22)
    local r_n = AddButton(self.page3, 360, -510, 110, 40, "清空",
        function() self:PickRotCrops("none") end, 22)
    table.insert(self.buttons[3], r_s)
    table.insert(self.buttons[3], r_a)
    table.insert(self.buttons[3], r_n)

    AddText(self.page3, PAD, -556,
        "轮作方案（每格照这个顺序换茬，走完一轮账本回到原点）：", 24, C.head)

    -- 方案列表随勾选重建，挂在 rot_root 下面
    self.rot_root = self.page3:AddChild(Widget("rot_root"))
    self.rot_root:SetPosition(0, 0, 0)

    AddText(self.page3, PAD, -870,
        "水位 = 一轮里三轴最低掉到多少（起始 30 估）：掉到 0 就吃压力、出不了巨大。", 20, C.dim)
    AddText(self.page3, PAD, -900,
        "作物只搬运不消灭：三轴总量守恒，换个吃富余那根轴的作物，格子自己就养回来。", 20, C.dim)
    AddText(self.page3, PAD, -930,
        "唯一真流失的是归还顶到 100（超出被丢掉）；每格一本账，全地照同一条链走就行。", 20, C.dim)

    -- 标题栏里的分页按钮（常驻，三页都登记）
    -- 高 40、y=-24 → 占 -4 ~ -44，整块落在 48 高的标题栏里
    -- ★ v2.5.0：多加一个「轮作」页，三个标签整体左移、收窄到 80 宽，
    --   右边界 620，给「复位」(650~730) 和按键提示 (780 起) 留够位置。
    local tab1 = AddButton(self, 430, -24, 80, 40, "信息",
        function() self:SwitchPage(1) end, 26)
    local tab2 = AddButton(self, 510, -24, 80, 40, "种植",
        function() self:SwitchPage(2) end, 26)
    local tab3 = AddButton(self, 590, -24, 80, 40, "轮作",
        function() self:SwitchPage(3) end, 26)
    self.tab_btns = { tab1, tab2, tab3 }
    for p = 1, 3 do
        table.insert(self.buttons[p], tab1)
        table.insert(self.buttons[p], tab2)
        table.insert(self.buttons[p], tab3)
    end

    -- 复位按钮：把面板挪回默认位置。
    -- 原来只有「右键标题栏」一个入口，太隐蔽 —— 面板被拖走之后找不到回来的路。
    -- 占 650~730，左边让开「轮作」(到 630)，右边让开按键提示 (从 780 起)。
    local reset = AddButton(self, 690, -24, 80, 40, "复位",
        function() self:ResetPos() end, 24)
    for p = 1, 3 do
        table.insert(self.buttons[p], reset)
    end

    self:RefreshTabs()

    self.page2:Hide()
    self.page3:Hide()
    self:RefreshDemo()
    self:RefreshRotation()

    self:RefreshRows()

    if START_OPEN then
        self:Show()
    else
        self:Hide()
    end

    self:StartUpdating()
end)

-- 刷第二页的「春夏秋冬」四字时令。当季绿色（好季节）或橙色（过季，种了吃压力）。
local function SetColourOf(t, c)
    t:SetColour(c[1], c[2], c[3], 1)
end

function FarmHelperPanel:RefreshSeasonBadges(season)
    if self.season_badges == nil then return end
    for _, crop in ipairs(CROPS) do
        local badges = self.season_badges[crop.id]
        if badges ~= nil then
            for si, sname in ipairs(SEASON_ORDER) do
                local t = badges[si]
                if t == nil then break end
                if sname == season then
                    -- 当前季节：是它的好季节就绿，不是就橙 —— 提醒「现在种会吃季节压力」
                    SetColourOf(t, crop.seasons[sname] and C.now or C.warn)
                elseif crop.seasons[sname] then
                    SetColourOf(t, C.text)
                else
                    SetColourOf(t, C.dim)
                end
            end
        end
    end
end

-- 按当前季节重建所有作物行
function FarmHelperPanel:RefreshRows()
    self.rows_root:KillAllChildren()

    local season = GetSeason()
    local y = ROW_TOP

    for _, crop in ipairs(CROPS) do
        -- 图标：作物一个、种子一个，分别排在两列名字的左边
        AddItemIcon(self.rows_root, crop.id, ".tex",       COL.icon1, y, ICON)
        AddItemIcon(self.rows_root, crop.id, "_seeds.tex", COL.icon2, y, ICON)

        -- 作物名
        AddText(self.rows_root, COL.name, y, PlantName(crop.id), DATA_SIZE, C.text)
        -- 种子名
        AddText(self.rows_root, COL.seed, y, SeedName(crop.id), DATA_SIZE, C.seed)

        -- 三种养分：显示「净变化」，不是单纯的消耗量。
        -- 作物每长一个阶段，吃掉某些养分的同时把等量的还给「它不消耗」的另几种
        -- （farm_plant_defs.lua:127-130 定归还项、farming_manager.lua:428 定归还量），
        -- 所以一格里有正有负才是一笔完整的账：
        --   -4 / +2 / +2  胡萝卜：吃掉 4 点催长剂，产出 2 点堆肥和 2 点粪肥
        local delta = NetDelta(crop.consume)
        local xs = { COL.n1, COL.n2, COL.n3 }
        for i = 1, 3 do
            local v = math.floor(delta[i] + 0.5)
            if v < 0 then
                AddText(self.rows_root, xs[i], y, "-" .. tostring(-v), DATA_SIZE, C.minus)
            elseif v > 0 then
                AddText(self.rows_root, xs[i], y, "+" .. tostring(v), DATA_SIZE, C.plus)
            else
                AddText(self.rows_root, xs[i], y, "0", DATA_SIZE, C.dim)
            end
        end

        -- 适宜季节：一个字一个文本框，方便单独给当前季节上高亮色
        local offset = 0
        for _, s in ipairs(SEASON_ORDER) do
            if crop.seasons[s] then
                local colour = (s == season) and C.now or C.text
                AddText(self.rows_root, COL.season + offset, y, SEASON_CN[s], DATA_SIZE, colour)
                -- ★ 季节字是逐字画的，间隔必须 > 单字宽（32 号字 ≈ 37px），
                --   否则相邻两个字会叠在一起。
                offset = offset + 40
            end
        end

        y = y - ROW_H
    end

    self:RefreshPlan(season)
    self:RefreshSeasonBadges(season)
    self.last_season = season
end

--==============================================================================
--  种植布局：一块 3×3 / 两块 3×3 叠起来
--
--  依据是 tuning.lua:5797-5800 那三个常量：
--    FARM_PLANT_SAME_FAMILY_MIN       = 4    每株要凑「自己 + 3 个同种」（含自己）
--    FARM_PLANT_SAME_FAMILY_RADIUS    = 4    半径 4 = 恰好一格（见下面的几何账）
--    FARM_PANT_OVERCROWDING_MAX_PLANTS= 10   同一块地皮超过 10 株才吃「过度拥挤」
--
--  ★★ v2.2.0 推翻了 v1.5 的两条结论。半径 4 是世界单位，而一格地皮的
--  中心距正好是 TILE_SCALE = 4（constants.lua）—— 所以家族搜索覆盖的是
--  「上下左右 4 个邻格」，**斜角不算**（邻格 4.0 够到，斜角 5.7 够不到）。
--  于是：
--    · 一块 3×3 → 三种各 3 株：谁也凑不齐 3 个同种邻居 → 全部出不了巨大
--    · 叠两块（3 列 × 6 行）→ 三种各 6 株：只有**中列** 6 株凑得齐；
--      角上的格子最多只有 2 个邻格，**在任何矩形地里都过不了家族**
--  养分倒是仍然能配平 —— 养分只看总账，家族才看每株的位置。
--==============================================================================

-- 把「每种几株」按比例放大到 target 格，再按行铺进 cols 列的网格。
-- 返回 rows：rows[r][c] = 作物 id
local function BuildLayoutGrid(ids, counts, target, cols)
    local sum = 0
    for i = 1, 3 do sum = sum + counts[i] end
    if sum <= 0 then return nil end

    -- 按比例分配，除不尽的余数从第一组开始依次补
    local out, used = { 0, 0, 0 }, 0
    for i = 1, 3 do
        out[i] = math.floor(counts[i] * target / sum)
        used = used + out[i]
    end
    local i = 1
    while used < target do
        out[i] = out[i] + 1
        used = used + 1
        i = (i % 3) + 1
    end

    -- 摊平成一维，再按行切开
    local flat = {}
    for k = 1, 3 do
        for _ = 1, out[k] do
            table.insert(flat, ids[k])
        end
    end

    local rows, row = {}, nil
    for idx = 1, #flat do
        if (idx - 1) % cols == 0 then
            row = {}
            table.insert(rows, row)
        end
        row[#row + 1] = flat[idx]
    end
    return rows
end

-- 本季配比里的三种作物（顺序 = 催长剂 / 堆肥 / 粪肥）
local function SeasonCropIds(season)
    local plan = BuildSeasonPlan(season)
    if plan == nil or #plan < 3 then return nil, nil end
    local ids, counts = {}, {}
    for i = 1, 3 do
        ids[i] = plan[i].id
        counts[i] = plan[i].n
    end
    return ids, counts
end

-- 画一个布局网格：每格一个小图标，格距 cell
-- 把一张布局图铺到 parent 上：暗底色（按作物分色）+ 真实作物图标。
-- ★ v2.0.0：以前只画一个纯色方块，现在换成游戏自带的物品图 ——
--   一眼就能认出是胡萝卜还是土豆，不用回头对照颜色表。
local function AddLayoutGrid(parent, rows, x0, y0, cell)
    if rows == nil then return end
    for r = 1, #rows do
        for c = 1, #rows[r] do
            local id = rows[r][c]
            if id ~= nil then
                local cx = x0 + (c - 1) * cell
                local cy = y0 - (r - 1) * cell
                local col = CropColour(id)
                local bg = parent:AddChild(Image("images/global.xml", "square.tex"))
                bg:SetSize(cell - 4, cell - 4)
                bg:SetPosition(cx, cy, 0)
                -- 底色压暗一档，别把图标本身的颜色盖掉
                bg:SetTint(col[1] * 0.5, col[2] * 0.5, col[3] * 0.5, 0.9)
                AddItemIcon(parent, id, ".tex", cx, cy, cell - 6)
            end
        end
    end
end

-- 画「一块地皮」：方框 = 一个 tile（4×4 世界单位），里面按配比密排。
-- ★ v2.6.0：取代按格铺的 BuildLayoutGrid + AddLayoutGrid。
--   同种作物**连着放**（挤成一堆）—— 家族判的是「半径 1 tile 内同种 ≥4 株」，
--   铺开就数不到了。
--   ★ 画成 **3×3 九宫格**（= 一块地皮锄满的样子），不是 4 列——
--     4 列看着就不像一块地皮了（玩家锄地出来就是九宫格）。
local function AddUnitLayout(parent, items, cx, cy)
    local bg = parent:AddChild(Image("images/global.xml", "square.tex"))
    bg:SetSize(UNIT_BOX, UNIT_BOX)
    bg:SetPosition(cx, cy, 0)
    bg:SetTint(0.32, 0.28, 0.20, 0.55)

    -- 3×3 九宫格，按行填充（同种连着放 = 挤成一堆）
    local idx = 0
    for _, it in ipairs(items) do
        for _ = 1, it.n do
            local c = idx % 3
            local r = math.floor(idx / 3)
            local x = cx + (c - 1) * UNIT_GAP
            local y = cy + UNIT_GAP - r * UNIT_GAP
            AddItemIcon(parent, it.id, ".tex", x, y, UNIT_ICON)
            idx = idx + 1
        end
    end
end

-- 单季配比的缓存：FindUnitPlan 是穷举（几千次循环），四季各算一次够用了，
-- 没必要每次刷新都重跑。CROPS 是常量表，缓存不会失效。
local plan_cache = {}
local function CachedPlan(s)
    if plan_cache[s] == nil then
        plan_cache[s] = FindUnitPlan(s) or false
    end
    if plan_cache[s] == false then return nil end
    return plan_cache[s]
end

-- 更新「四季推荐」表 + 右上角那块地皮的密排图
function FarmHelperPanel:RefreshPlan(season)
    -- ① 四季推荐：每季一行「季节　配比　N 块」，当前季高亮
    --    （本轮换掉了 v2.5.1 的「本季种法（轮作链）」—— 轮作不再主推）
    if self.season_row ~= nil then
        for _, s in ipairs(SEASON_ORDER) do
            local row = self.season_row[s]
            if row ~= nil then
                local p = CachedPlan(s)
                local txt
                if p == nil then
                    txt = SEASON_CN[s] .. "　凑不出零和配比"
                else
                    local parts = {}
                    for _, it in ipairs(p.items) do
                        table.insert(parts, string.format("%s %d", PlantName(it.id), it.n))
                    end
                    txt = string.format("%s　%s　%d 块",
                        SEASON_CN[s], table.concat(parts, " + "), p.blocks)
                end
                if row:GetString() ~= txt then row:SetString(txt) end
                SetColourOf(row, (s == season) and C.now or C.text)
            end
        end
    end

    -- ② 图区：当前季节的前几个方案，各画一块地皮的九宫格 + 下标配比
    --    ★ v2.6.9：从「只画一个」改成「并排画多个」——
    --      手里的种子凑不出主方案时，能直接看备选长什么样。
    if self.layout_one_root ~= nil then
        self.layout_one_root:KillAllChildren()
        local list = (season ~= nil) and UnitPlans(season, UNIT_MAX) or {}
        for i, p in ipairs(list) do
            local cx = UNIT_FIRST_CX + (i - 1) * UNIT_STEP
            AddUnitLayout(self.layout_one_root, p.items, cx, UNIT_CY)
            -- 下标：序号 + 每块配比 + 块数（"番茄4+土豆4 x1" 这种紧凑写法，
            -- 半角 x 是 ASCII，TALKINGFONT 一定有字形 —— 别写成「×」）
            local parts = {}
            for _, it in ipairs(p.items) do
                table.insert(parts, string.format("%s%d", PlantName(it.id), it.n))
            end
            -- ★ v2.6.9：这个方案家族够不够，**逐株真算**（和第二页同一套几何）。
            --   冬季那几种在九宫格下跨块凑不满，标成橙色 —— 别让人照着种还以为能成。
            local _fp, _fok, fbad = TileFamilyCount(p.items, p.blocks)
            local col = (fbad > 0) and C.warn or ((i == 1) and C.text or C.dim)
            -- 拆两行：三个作物的方案（冬季那种）一行放不下会被挤出面板。
            -- ★ 必须 ANCHOR_MIDDLE —— 默认左对齐时左边缘落在 cx 上，
            --   第三个图（cx=900）的标注会顶出面板右边界（_layout.py 抓到过 26.9px）。
            AddText(self.layout_one_root, cx, UNIT_CY - 88,
                string.format("%d. %s", i, table.concat(parts, "+")), 13, col,
                ANCHOR_MIDDLE)
            AddText(self.layout_one_root, cx, UNIT_CY - 104,
                string.format("x%d 块", p.blocks), 13, col, ANCHOR_MIDDLE)
        end
    end
end

--==============================================================================
--  六之二、第二页：种子数量 / 地皮形状 / 示意图
--==============================================================================

-- 作物属于哪一组：1 = 主要吃催长剂，2 = 堆肥，3 = 粪肥。
-- 番茄 (2,2,0) 和西瓜 (0,2,2) 同时吃两种，方向不唯一，返回 nil（不参与排布）。
-- 家族要求：同种作物 ≥4 株（含自己），判定半径 4 世界单位。
-- tuning.lua:5799-5800 FARM_PLANT_SAME_FAMILY_MIN / FARM_PLANT_SAME_FAMILY_RADIUS
local FAMILY_MIN = 4
local FAMILY_R   = 4     -- 判定半径 = TILE_SCALE，所以「一块地皮」正好是它的量程

-- ★ v2.6.8：摆位与家族判定用的两个几何常量
--   SP  = FARM_TILL_SPACING（相邻土堆最小间距）
--   GAP = TILE_SCALE（相邻两块地皮的中心距）
local TILL_SP, TILE_GAP = 1.25, 4.0

-- ★ v2.3.0 配平器的代价模型（缺 1 点养分要付出的「价值」）：
--   按获取难度定权重 —— 催长剂只能靠烂鱼/合成瓶（最难），堆肥/粪肥都是垃圾再生。
--   想改三者的相对贵贱，只动这三个数字。
local STAGE_COUNT = 4          -- 一季约 4 个耗肥阶段（sprout/small/med/grown）
local PRICE = { 4, 1.2, 1 }    -- 顺序 = { 催长剂, 堆肥, 粪肥 }

-- 按 id 取作物定义
local function CropById(id)
    for _, c in ipairs(CROPS) do
        if c.id == id then return c end
    end
    return nil
end

local function CropGroup(crop)
    local d = NetDelta(crop.consume)
    local axis, negs = nil, 0
    for i = 1, 3 do
        if d[i] < 0 then
            negs = negs + 1
            axis = i
        end
    end
    if negs == 1 then return axis end
    return nil
end

--==============================================================================
--  每块地皮的配比（v2.6.0 重写）
--
--  ★ 旧版 BuildSeasonPlan 给的配比出不了巨大作物，两个根因：
--    1. 只收「恰好消耗一种养分」的作物 → 把番茄 / 西瓜（混合型）排除了。
--       可**两个单轴型的净变化相加不可能为 0**（会推出 a = -b）；
--       互补对必须是「混合型 + 单轴型」：番茄+土豆、西瓜+胡萝卜。
--       旧算法于是只能给出 1:1:1，而 1:1:1 在 9 株时每种只有 3 株 —— 家族不够。
--    2. 只算「整片地加总为零」，没意识到养分是**按地皮（tile）记账**的。
--       摊到不同 tile 只是总和为零，每个 tile 照样单向抽干。
--
--  新模型（五个来源交叉验证 + 源码核对，不闭门造车）：
--    · 一台耕地机开 2×2 = 4 块地皮；一块地皮 = 一个 tile = 4×4 世界单位
--      （GamerEmpire 指南："4 farm soil turfs and 36 farm soils"）
--    · 一块地皮最多锄 16 个土堆（间距 FARM_TILL_SPACING = 1.25，每边 4 个位置），
--      但同 tile 超过 10 株吃「拥挤」压力 → 常见 9 株，最优 10 株
--      （Snapping tills 讨论区："the max ... is 10 per tile, or 40 per 2x2"）
--    · **养分按 tile 记账** → 每个 tile 内的比例就要零和
--      （Fandom wiki："Nutrients are calculated per-tile, not in a radius around
--        each plant ... while also connecting the plants to their families in
--        other tiles"）
--    · **家族可以跨 tile 凑**（半径 1 tile 内同种 ≥4 株）
--      （note.com：6 番茄 + 3 火龙果 要两块田并排、火龙果靠边界放）
--==============================================================================

local UNIT_SIZES = { 6, 8, 9 }    -- 每块地皮的株数候选（上限 9 = 能锄的坑数）

-- ★ v2.6.9：把「穷举 + 排序」抽成 EnumUnitPlans，好**一次拿到多个方案** ——
--   面板现在会列出主方案 + 备选（手里的种子凑不出主方案时有的选）。
--   排序规则和配平器同一套：单块自足 > 种类少 > 株数多 > 留种优先级高。
--
--   ★ 并且补了一条**稳定 tie-breaker**（配比签名的字符串比较）：
--     Lua 的 `table.sort` 是**不稳定**排序，同 key 的候选顺序每次跑可能不一样 ——
--     那会让「面板上的主方案自己变来变去」。离线测试（_test_algo.py 第五节）
--     验过：加签名之前 40 次乱序里结果虽稳，但那是运气，加上才真稳。
local function UnitPlanSig(items)
    local parts = {}
    for _, it in ipairs(items) do
        table.insert(parts, string.format("%s=%d", it.id, it.n))
    end
    table.sort(parts)
    return table.concat(parts, ",")
end

local function EnumUnitPlans(season)
    if season == nil then return {} end

    local ids = {}
    for _, c in ipairs(CROPS) do
        if c.seasons[season] then table.insert(ids, c.id) end
    end
    local n = #ids
    if n < 2 then return {} end

    -- 净变化预计算：三重循环里反复算 NetDelta 太亏
    local nd = {}
    for _, id in ipairs(ids) do
        nd[id] = NetDelta(CropById(id).consume)
    end

    local function zero(items)
        local s1, s2, s3 = 0, 0, 0
        for _, it in ipairs(items) do
            local d = nd[it.id]
            s1 = s1 + d[1] * it.n
            s2 = s2 + d[2] * it.n
            s3 = s3 + d[3] * it.n
        end
        return math.abs(s1) < 0.001 and math.abs(s2) < 0.001
               and math.abs(s3) < 0.001
    end

    -- 每种凑够 4 株（家族）要几块地皮。1 = 单块自足。
    local function need_blocks(items)
        local need = 1
        for _, it in ipairs(items) do
            if it.n > 0 then
                local b = math.ceil(FAMILY_MIN / it.n)
                if b > need then need = b end
            end
        end
        return need
    end

    local all = {}
    local function consider(items, total)
        -- ★★★ v2.6.5 修 bug：这里原来**漏了零和检查**。
        --   后果是「胡萝卜 + 洋葱」这种「两个都吃生长素的单轴作物」也能进候选，
        --   排序（单块自足 > 种类少 > 株数多）再把它一路顶到面板上 ——
        --   玩家一眼就看出来了：**两个同轴作物的净变化相加永远不可能为 0**。
        --   （配平器那边的 SearchTilePlan 有这道检查，只有第一页漏了。）
        if not zero(items) then return end
        table.insert(all, { items = items, total = total,
                            blocks = need_blocks(items),
                            keep = KeepScore(items),
                            sig = UnitPlanSig(items) })
    end

    for _, total in ipairs(UNIT_SIZES) do
        -- 两种作物
        for i = 1, n do
            for j = i + 1, n do
                for ni = 1, total - 1 do
                    consider({ { id = ids[i], n = ni },
                               { id = ids[j], n = total - ni } }, total)
                end
            end
        end
        -- 三种作物（i<j<k，免得把同一组合算 6 遍）
        for i = 1, n do
            for j = i + 1, n do
                for k = j + 1, n do
                    for ni = 1, total - 2 do
                        for nj = 1, total - ni - 1 do
                            local nk = total - ni - nj
                            if nk >= 1 then
                                consider({ { id = ids[i], n = ni },
                                           { id = ids[j], n = nj },
                                           { id = ids[k], n = nk } }, total)
                            end
                        end
                    end
                end
            end
        end
    end

    -- 单块自足 > 种类少 > 株数多 > 留种优先级高 > 签名（稳定 tie-breaker）
    table.sort(all, function(a, b)
        if a.blocks ~= b.blocks then return a.blocks < b.blocks end
        if #a.items ~= #b.items then return #a.items < #b.items end
        if a.total ~= b.total then return a.total > b.total end
        if a.keep ~= b.keep then return a.keep > b.keep end
        return a.sig < b.sig
    end)
    return all
end

-- 主方案（给只关心第一个的调用处，比如启动自检）
FindUnitPlan = function(season)
    return EnumUnitPlans(season)[1]
end

-- 前 N 个方案 —— 面板用来列「主方案 + 备选」
--   ★ 赋值式（不是 `local function`）—— 上面已前置声明，见那段注释
UnitPlans = function(season, want)
    local all = EnumUnitPlans(season)
    local out = {}
    for i = 1, math.min(want or 3, #all) do
        out[i] = all[i]
    end
    return out
end

--==============================================================================
--  配平器用：在**你手里有的**作物里找「每块地皮的零和配比」（v2.6.0 新增）
--
--  ★ 和上面 FindUnitPlan 只有一处不同：候选池。
--    那边用「当季全部作物」，这边用「你填了数量的那些」。规则完全一样：
--      · 养分按地皮记账 → **每一块地皮自己**就要是零和配比
--      · 家族可以跨地皮凑 → 少数派那种靠边界放
--      · 每块地皮 ≤ 10 株（同 tile 拥挤上限）
--    返回 { items = {{id, n}}, total = 每块株数, blocks = 要几块 }，
--    其中 items 里每种的 n 是**每块的株数**，总数 = n × blocks。
--==============================================================================

-- ★ 每块地皮按 **9 株**设计（3×3 九宫格）。
--
--   ★ v2.6.8 更正：这个数**不是源码里的硬上限**，是保守值。先前这里写着
--   「土堆不能贴边 → 每边 3 个」，那是我的推测 —— 独立审查对照源码后指出：
--   `map.lua:209-212 CanTillSoilAtPoint` 只要求「落点是农田地皮 + 间距 ≥ 1.25」，
--   贴边落点仍在地皮内、没有余量要求；而且 `TILLSOIL_IGNORE_TAGS` 里
--   显式含 `"soil"`（map.lua:194-196），已有土堆会被间距检查忽略。
--   理论上限是 4×4 = 16 个坑位（要 Snapping tills 那类 mod 辅助才能精确摆出来）。
--
--   那为什么取 9：① 手锄的常规做法就是九宫格（wiki 的「每块田地 9 格」）；
--   ② 它稳稳低于拥挤上限（同 tile 10 株，tuning.lua:5797），不会踩线。
--   两个数别混：**10 是「能站几株」，9 是「我们推荐种几株」**。
local TILE_MAX_MOUNDS = 9

local function SearchTilePlan(avail, per_tile)
    local ids, nd = {}, {}
    for _, crop in ipairs(CROPS) do
        if (avail[crop.id] or 0) > 0 then
            table.insert(ids, crop.id)
            nd[crop.id] = NetDelta(crop.consume)
        end
    end
    local n = #ids
    if n < 2 then return nil end

    local all = {}
    local function consider(items, total)
        -- 零和？
        local s = { 0, 0, 0 }
        for _, it in ipairs(items) do
            local d = nd[it.id]
            for i = 1, 3 do s[i] = s[i] + d[i] * it.n end
        end
        if math.abs(s[1]) > 0.001 or math.abs(s[2]) > 0.001
           or math.abs(s[3]) > 0.001 then
            return
        end
        -- 家族要几块；手里够不够种满这几块
        local blocks = 1
        for _, it in ipairs(items) do
            local b = math.ceil(FAMILY_MIN / it.n)
            if b > blocks then blocks = b end
        end
        for _, it in ipairs(items) do
            if (avail[it.id] or 0) < it.n * blocks then return end
        end
        table.insert(all, { items = items, total = total, blocks = blocks,
                            keep = KeepScore(items) })
    end

    for total = 3, per_tile do
        -- 两种作物
        for i = 1, n do
            for j = i + 1, n do
                for ni = 1, total - 1 do
                    consider({ { id = ids[i], n = ni },
                               { id = ids[j], n = total - ni } }, total)
                end
            end
        end
        -- 三种作物
        for i = 1, n do
            for j = i + 1, n do
                for k = j + 1, n do
                    for ni = 1, total - 2 do
                        for nj = 1, total - ni - 1 do
                            local nk = total - ni - nj
                            if nk >= 1 then
                                consider({ { id = ids[i], n = ni },
                                           { id = ids[j], n = nj },
                                           { id = ids[k], n = nk } }, total)
                            end
                        end
                    end
                end
            end
        end
    end
    if #all == 0 then return nil end

    -- 单块自足 > 种类少 > 株数多 > 留种优先级高（与 FindUnitPlan 同一套）
    table.sort(all, function(a, b)
        if a.blocks ~= b.blocks then return a.blocks < b.blocks end
        if #a.items ~= #b.items then return #a.items < #b.items end
        if a.total ~= b.total then return a.total > b.total end
        if a.keep ~= b.keep then return a.keep > b.keep end
        return false
    end)
    return all[1], all
end

--==============================================================================
--  轮作（v2.5.0 新增）
--
--  为什么非要这一页：CycleNutrientsAtPoint() 是**按格**记账的
--  （farming_manager.lua:400 进来先 GetTileNutrients(x, y)，按地皮格子存）。
--  第二页的配平只保证「整块地这一茬的净变化加起来是 0」；
--  可把 9 株番茄 + 9 株土豆摊进 18 个格子，每格都是单向搬运 ——
--  番茄格的催长剂、堆肥一路掉到 0，土豆格的粪肥一路掉到 0。
--
--  那「缺肥」到底是什么？看源码这两行就明白了：
--      consumptioncount = math.min(nutrients[n_type], count)   -- 有多少扣多少
--      total_restore_count = total_restore_count + consumptioncount
--      depleted = depleted or consumptioncount ~= count
--  扣的量 = 还的量，所以**三轴总量是守恒的**：作物只搬运，不生产也不消灭。
--  连种同一种的后果不是「养分用光了」，而是**全堆到一根轴上、另两根见底**。
--  见底之后那一茬会扣不够 → depleted → 吃一次压力（出不了巨大作物）。
--
--  ★ 唯一真会流失养分的地方在 AddTileNutrients()：
--        math.clamp(_n + nutrient, 0, 100)
--    归还时把某根轴顶过 100，超出的部分直接丢掉。扣不够反而不流失
--    （扣得少、还得也少，两边抵消）。
--
--  既然总量守恒，救回来就不用施肥 —— 换个「吃富余那根轴」的作物，
--  它自己会把养分搬回去。所以真正省事的种法，是让**同一格**的前后茬互相抵消：
--  上一茬把养分从第 1 轴搬到第 3 轴，下一茬再搬回来。
--  净变化三项之和恒为 0，只要找出加起来为 0 的作物链，每格照着轮就行。
--==============================================================================

-- 模拟用的起始水位。tuning.lua:5748 STARTING_NUTRIENTS_MIN/MAX = 20/40，取中。
local SOIL_START = 30

-- 把一串作物按顺序种在同一格，逐阶段模拟（跟源码一致：
-- 每个生长阶段扣一次、再还一次，最后 AddTileNutrients 钳到 0~100）。
-- low  = 这一轮里三轴最低掉到多少（掉到 0 就扣不够、吃压力）
-- high = 最高顶到多少（顶到 100 就会丢掉超出的部分，真流失）
local function SimulateChain(chain)
    local soil = { SOIL_START, SOIL_START, SOIL_START }
    local low, high = SOIL_START, SOIL_START

    for _, id in ipairs(chain) do
        local crop = CropById(id)
        if crop == nil then return nil end
        local consume = crop.consume

        -- 归还到「不消耗」的那几根轴上。S/M/L 的总量都能被轴数整除，
        -- 所以源码里那段「余数随机分配」在本作数值下永远是 0，不用管。
        local zeros = 0
        for i = 1, 3 do
            if consume[i] == 0 then zeros = zeros + 1 end
        end

        for _ = 1, STAGE_COUNT do
            local got = 0
            for a = 1, 3 do
                if consume[a] > 0 then
                    local take = math.min(soil[a], consume[a])  -- 有多少扣多少
                    soil[a] = soil[a] - take
                    got = got + take
                end
            end
            if zeros > 0 then
                local each = math.floor(got / zeros)
                for a = 1, 3 do
                    if consume[a] == 0 then
                        soil[a] = soil[a] + each
                    end
                end
            end
            for a = 1, 3 do
                if soil[a] < 0   then soil[a] = 0   end
                if soil[a] > 100 then soil[a] = 100 end
                if soil[a] < low  then low  = soil[a] end
                if soil[a] > high then high = soil[a] end
            end
        end
    end

    local closed = (soil[1] == SOIL_START
                and soil[2] == SOIL_START
                and soil[3] == SOIL_START)
    return { closed = closed, low = low, high = high }
end

-- 在 ids 里找出所有能闭合的轮作链（长度 2 或 3，同种作物可重复出现）。
-- 排序：全当季优先 > 茬数少优先 > 水位高优先 > 峰位低优先 > 种类多优先。
-- ★ 注意：这里用的是前面 `local FindChains` 的前向声明，别再写 local。
FindChains = function(ids, season)
    local best = {}   -- 键 = 排序后的作物集合，同一个循环换个起点算同一条

    local function consider(chain)
        local sim = SimulateChain(chain)
        if sim == nil or not sim.closed then return end

        local sorted = {}
        for _, id in ipairs(chain) do table.insert(sorted, id) end
        table.sort(sorted)
        local key = table.concat(sorted, ",")

        local old = best[key]
        if old ~= nil and old.low >= sim.low then return end

        local all_season = true
        for _, id in ipairs(chain) do
            local crop = CropById(id)
            if crop == nil or crop.seasons == nil or not crop.seasons[season] then
                all_season = false
            end
        end

        local kinds, kind_n = {}, 0
        for _, id in ipairs(chain) do kinds[id] = true end
        for _ in pairs(kinds) do kind_n = kind_n + 1 end

        best[key] = {
            chain = chain, low = sim.low, high = sim.high,
            all_season = all_season, kind_n = kind_n,
        }
    end

    local n = #ids
    for i = 1, n do
        for j = 1, n do
            consider({ ids[i], ids[j] })
            for k = 1, n do
                consider({ ids[i], ids[j], ids[k] })
            end
        end
    end

    local out = {}
    for _, v in pairs(best) do table.insert(out, v) end

    table.sort(out, function(x, y)
        if x.all_season ~= y.all_season then return x.all_season end
        if #x.chain     ~= #y.chain     then return #x.chain < #y.chain end
        if x.low        ~= y.low        then return x.low > y.low end
        -- 顶到 100 会丢养分，峰位低的更干净
        if x.high       ~= y.high       then return x.high < y.high end
        return x.kind_n > y.kind_n
    end)

    return out
end

-- − / + 按钮
function FarmHelperPanel:AdjustSeed(id, delta)
    local cur = self.seed_counts[id] or 0
    cur = math.max(0, math.min(99, cur + delta))
    self.seed_counts[id] = cur

    -- 手动改数量 = 不再要看配平建议，退出建议模式
    self.plan_counts = nil

    local t = self.seed_texts[id]
    if t ~= nil then t:SetString(tostring(cur)) end

    self:RefreshDemo()
end

-- ★ v2.6.8：`SetTileMode` 已删（按钮一起删了，算法不再读 tile_mode）。

--──────────────────────────────────────────────────────────────────────────────
-- ★ v2.3.0 配平器 ─────────────────────────────────────────────────────────────
--──────────────────────────────────────────────────────────────────────────────

-- ★ v2.6.7：`AdjustFertItem` 和 `RefreshFertSummary` 一起删了
--   （对应第二页那块肥料库存输入网格）。详见 FERT_ITEMS 处的注释。

function FarmHelperPanel:ToggleFamily()
    self.family_mode = not self.family_mode
    if self.family_btn ~= nil and self.family_btn.label_text ~= nil then
        self.family_btn.label_text:SetString(
            self.family_mode and "考虑家族：开" or "考虑家族：关")
    end
    -- ★ v2.6.8：补上刷新 —— 以前拨这个开关画面纹丝不动（只有再点「一键配平」
    --   才有区别），玩家会以为开关坏了。而 family_mode 只影响候选池，
    --   不重画就完全看不出来。
    self:RefreshDemo()
end

-- 一键配平：在「我填的数量」范围内为这块地找最省肥料的组合。
-- ★ v2.4.3 换成**精确算法**（不再爬山近似）：
--   关键观察：单轴作物对组 g 的净贡献向量只由「该组总消耗 s」决定 ——
--   三组各消耗 s1/s2/s3 时，净变化 D_j = (S − 3·s_j)/2（S = s1+s2+s3）。
--   所以同组同 s 的方案代价完全等价：每组只需为每个 s 记一个代表方案，
--   再把三组的 s 组合 + 混合型数量扫一遍，结果保证全局最优。
-- 目标（按优先级）：
--   1. 全季缺口代价最小 —— 每阶段净变化 × STAGE_COUNT = 全季缺口，
--      先用肥料库存抵，抵不完的按 PRICE（获取难度）计代价；
--   2. 同代价下尽量把地种满。
-- 考虑家族（开）：只用当季作物，每种要么 0 株要么 ≥4 株；
--   家族的几何判定照旧由诊断行逐株汇报（3 列格子里只有中列能全过，四角天生不够）。
-- 结果存 plan_counts（建议模式），不覆盖你填的数量。
--──────────────────────────────────────────────────────────────────────────────
-- 一键配平（v2.6.0 重写）
--
--  ★ 旧版算的是「**整片地**加起来为零」的最优组合 —— 那是错的。
--    养分**按地皮（tile）记账**：farming_manager.lua:400 的 CycleNutrientsAtPoint
--    进来第一行就是 GetTileCoordsAtPoint，把坐标塌缩成脚下那一格。
--    把互补作物摊到不同地皮只是「总和为零」，每一块地皮照样单向抽干。
--
--    新口径：找「**一块地皮内**的零和配比」，然后每块都照着种。
--    家族是半径 1 tile 的搜索、不分地皮，所以少数派那种靠边界放就能跨块凑。
--
--  ★ 旧版的第二个错：把「混合型」（番茄/西瓜，吃两轴）隔离出去只当补丁。
--    可**两个单轴作物的净变化相加不可能为 0**（会推出 a = −b），
--    互补对恰恰必须是「混合型 + 单轴型」。新版让所有作物平等参与零和搜索。
--
--  ★ 三个已验证的四季方案（_sim.py 跑过整季：好季节、水分满足、每阶段照料）：
--      秋/春  4 番茄 + 4 土豆（8 株，1 块，7 茬，100% 巨大）
--      夏     6 番茄 + 3 火龙果（9 株，2 块，火龙果靠边界）
--      冬     3 南瓜 + 3 芦笋 + 3 土豆（9 株，2 块，少的那种靠边界）
--    三种压力源（家族 / 养分 / 拥挤）次数全是 0，水位每茬回到同一组数字。
--──────────────────────────────────────────────────────────────────────────────
function FarmHelperPanel:AutoBalance()
    local season = GetSeason()
    local fam = self.family_mode and true or false

    -- ① 候选：你填了数量的作物（家族模式下再限当季）
    local avail = {}
    for _, crop in ipairs(CROPS) do
        local n = self.seed_counts[crop.id] or 0
        if n > 0 and ((not fam) or season == nil or crop.seasons[season]) then
            avail[crop.id] = n
        end
    end

    -- ② 找「每块地皮的零和配比」
    local plan = SearchTilePlan(avail, TILE_MAX_MOUNDS)
    if plan == nil then
        print("[FarmHelper] 配平：手里的作物凑不出零和配比 —— 至少要能凑出互补的"
              .. "两三种（比如番茄 + 土豆，或者三种单轴作物各一样）")
        return
    end

    -- ③ 每块地皮都照这个配比种，一共种 plan.blocks 块。
    --   ★ 建议模式：结果存 plan_counts，**不覆盖你填的数量**（v2.4.1 的约定）。
    self.plan_counts = {}
    for _, it in ipairs(plan.items) do
        self.plan_counts[it.id] = it.n * plan.blocks
    end
    self:RefreshDemo()

    local parts = {}
    for _, it in ipairs(plan.items) do
        table.insert(parts, string.format("%s %d 株", PlantName(it.id), it.n))
    end
    print(string.format(
        "[FarmHelper] 配平完成：每块地皮 %d 株（%s）× %d 块 = %d 株；"
        .. "每块自己零和、不用施肥（建议模式，你填的数量没动）",
        plan.total, table.concat(parts, " + "), plan.blocks,
        plan.total * plan.blocks))
end

-- ⚠ 旧算法留档（v2.6.0 起不再调用，改名以免和新口径混在一起）：
--   它算的是「**整片地**加起来为零」的最优组合。养分是按地皮记账的，
--   所以那个解把互补作物摊到不同地皮时，每块地皮照样单向抽干。
function FarmHelperPanel:AutoBalanceLegacy()
    local season = GetSeason()
    local capacity = (self.tile_mode == 2) and 18 or 9
    local fam = self.family_mode and true or false

    -- 候选池：我填了数量的作物；家族模式下进一步限当季。
    --   混合型（两个负轴：番茄/西瓜）单独标记，不参与三轴分组。
    local pool = {}
    for _, crop in ipairs(CROPS) do
        local n = self.seed_counts[crop.id] or 0
        if n > 0 and ((not fam) or season == nil or crop.seasons[season]) then
            local d = NetDelta(crop.consume)
            local neg = 0
            for i = 1, 3 do
                if d[i] < 0 then neg = neg + 1 end
            end
            if neg >= 2 then
                table.insert(pool, { id = crop.id, avail = n, d = d, mixed = true })
            else
                local g, size = 1, 0
                for i = 1, 3 do
                    if d[i] < 0 then
                        g = i
                        size = -d[i]
                    end
                end
                table.insert(pool, { id = crop.id, avail = n, d = d, g = g, size = size,
                    is_season = (season == nil) or crop.seasons[season] })
            end
        end
    end
    if #pool == 0 then
        print("[FarmHelper] 配平：先在上方把手里有的作物数量加上去")
        return
    end

    -- 当季的排前面：同代价的候选里优先选当季的（table.sort 不稳定，用 order 破平）
    for i, it in ipairs(pool) do it.order = i end
    table.sort(pool, function(a, b)
        if (a.mixed ~= nil) ~= (b.mixed ~= nil) then return b.mixed ~= nil end
        if a.is_season ~= b.is_season then return a.is_season == true end
        return a.order < b.order
    end)

    -- ① 组内枚举：s → 代表方案（同 s 保留株数最多的一支；先到者 = 当季优先）
    local groups = { {}, {}, {} }
    local mixed_items = {}
    for _, it in ipairs(pool) do
        if it.mixed then
            table.insert(mixed_items, it)
        else
            table.insert(groups[it.g], it)
        end
    end

    local s_maps = { {}, {}, {} }
    local function enum_group(gi)
        local smap = s_maps[gi]
        local items = groups[gi]
        local chosen = {}
        local function rec(idx, s, total)
            local e = smap[s]
            if e == nil or total > e.total then
                local c = {}
                for k, v in pairs(chosen) do c[k] = v end
                smap[s] = { counts = c, total = total }
            end
            if idx > #items then return end
            local it = items[idx]
            local maxn = math.min(it.avail, capacity - total)
            for n = 0, maxn do
                if (not fam) or n == 0 or n >= FAMILY_MIN then
                    if n > 0 then chosen[it.id] = n end
                    rec(idx + 1, s + n * it.size, total + n)
                    if n > 0 then chosen[it.id] = nil end
                end
            end
        end
        rec(1, 0, 0, {})
    end
    enum_group(1)
    enum_group(2)
    enum_group(3)

    -- ② 混合型枚举（数量 0..上限；家族模式同样 0 或 ≥4）
    local mixed_opts = { { counts = {}, net = { 0, 0, 0 }, total = 0 } }
    if #mixed_items > 0 then
        local chosen = {}
        local function rec(idx, n1, n2, n3, total)
            if idx > #mixed_items then
                local c = {}
                for k, v in pairs(chosen) do c[k] = v end
                table.insert(mixed_opts,
                    { counts = c, net = { n1, n2, n3 }, total = total })
                return
            end
            local it = mixed_items[idx]
            local maxn = math.min(it.avail, capacity - total)
            for n = 0, maxn do
                if (not fam) or n == 0 or n >= FAMILY_MIN then
                    if n > 0 then chosen[it.id] = n end
                    rec(idx + 1, n1 + it.d[1] * n, n2 + it.d[2] * n, n3 + it.d[3] * n, total + n)
                    if n > 0 then chosen[it.id] = nil end
                end
            end
        end
        rec(1, 0, 0, 0, 0)
    end

    -- ③ 三组 s 组合 × 混合型方案，一遍扫出全局最优。
    --   s 的键是消耗点数的倍数（4/8），实际键数 ≤ 40，三重循环瞬间跑完。
    local best_cost, best_tot, best_pick = nil, 0, nil
    for s1, A in pairs(s_maps[1]) do
        for s2, B in pairs(s_maps[2]) do
            local base = A.total + B.total
            if base <= capacity then
                for s3, C in pairs(s_maps[3]) do
                    local base_total = base + C.total
                    if base_total <= capacity then
                        local S = s1 + s2 + s3
                        for _, mo in ipairs(mixed_opts) do
                            local total = base_total + mo.total
                            if total <= capacity then
                                local cost = 0
                                local ds = { (S - 3 * s1) / 2 + mo.net[1],
                                             (S - 3 * s2) / 2 + mo.net[2],
                                             (S - 3 * s3) / 2 + mo.net[3] }
                                for j = 1, 3 do
                                    local deficit = math.max(0, -ds[j]) * STAGE_COUNT
                                        - (self.fert_counts[j] or 0)
                                    cost = cost + math.max(0, deficit) * PRICE[j]
                                end
                                if best_cost == nil or total > best_tot
                                    or (total == best_tot and cost < best_cost - 0.001) then
                                    best_cost, best_tot = cost, total
                                    best_pick = { A = A, B = B, C = C, mo = mo }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    if best_pick == nil then
        print("[FarmHelper] 配平：候选数量和地皮容量对不上，怎么摆都放不下")
        return
    end

    -- ④ 还原成每种作物的株数
    local x = {}
    for _, part in ipairs({ best_pick.A, best_pick.B, best_pick.C, best_pick.mo }) do
        for id, n in pairs(part.counts) do x[id] = n end
    end

    -- ★ v2.4.1：结果存进 plan_counts（**建议模式**），不再覆盖你填的数量。
    --   旧行为是直接写回 seed_counts —— 你填了 14 种的库存，点一下全被清成
    --   建议值，输入就丢了。现在示意图/诊断按建议画，你填的数量原样保留；
    --   手动改任意作物的数量（AdjustSeed）即退出建议模式。
    self.plan_counts = {}
    for _, crop in ipairs(CROPS) do
        self.plan_counts[crop.id] = x[crop.id] or 0
    end
    self:RefreshDemo()
    local D = { 0, 0, 0 }
    for _, it in ipairs(pool) do
        local n = x[it.id] or 0
        if n > 0 then
            for i = 1, 3 do D[i] = D[i] + it.d[i] * n end
        end
    end
    print(string.format(
        "[FarmHelper] 配平完成：%d 格 / 家族 %s / 需补 催%d 堆%d 粪%d（建议模式，输入未动）",
        capacity, tostring(fam),
        math.max(0, -D[1]) * STAGE_COUNT,
        math.max(0, -D[2]) * STAGE_COUNT,
        math.max(0, -D[3]) * STAGE_COUNT))
end

-- 切页
-- ★ v2.5.0：两页变三页。先把三页全藏掉再单独 Show，
--   免得漏掉哪一块导致两页内容叠在一起。
function FarmHelperPanel:SwitchPage(n)
    self.cur_page = n
    self.page1:Hide()
    self.page2:Hide()
    self.page3:Hide()

    if n == 1 then
        self.page1:Show()
    elseif n == 2 then
        self.page2:Show()
        self:RefreshDemo()
    else
        self.page3:Show()
        self:RefreshRotation()   -- 换季之后默认勾选会变，进页时重算一次
    end

    self:RefreshTabs()
end

-- 标签按钮的底色：当前页亮一点，另一页暗一点，一眼能看出在哪一页
function FarmHelperPanel:RefreshTabs()
    if self.tab_btns == nil then return end
    for i, b in ipairs(self.tab_btns) do
        b.tab_on = (i == self.cur_page)
        if b.bg ~= nil then
            b.bg:SetTint(1, 1, 1, b.tab_on and TAB_ALPHA_ON or BUTTON_ALPHA)
        end
    end
end

--──────────────────────────────────────────────────────────────────────────────
--  第三页：勾选作物的三个动作（v2.5.0）
--──────────────────────────────────────────────────────────────────────────────

-- 单个作物：要 / 不要 反过来
function FarmHelperPanel:ToggleRotCrop(id)
    self.rot_on[id] = not self.rot_on[id]
    self:RefreshRotation()
end

-- 批量：只选当季 / 全选 / 清空
function FarmHelperPanel:PickRotCrops(mode)
    local season = GetSeason()
    for _, c in ipairs(CROPS) do
        if mode == "all" then
            self.rot_on[c.id] = true
        elseif mode == "none" then
            self.rot_on[c.id] = false
        else
            self.rot_on[c.id] = (season ~= nil and c.seasons ~= nil
                                 and c.seasons[season]) or false
        end
    end
    self:RefreshRotation()
end

-- 重算方案列表。勾选项变了、换季了、进这一页了，都走一遍。
function FarmHelperPanel:RefreshRotation()
    if self.rot_root == nil then return end
    self.rot_root:KillAllChildren()

    local season = GetSeason()

    -- ① 先刷 14 行的开关文字和时令标记
    for _, c in ipairs(CROPS) do
        local b = self.rot_btn[c.id]
        if b ~= nil and b.label_text ~= nil then
            b.label_text:SetString(self.rot_on[c.id] and "要" or "不要")
            SetColourOf(b.label_text, self.rot_on[c.id] and C.now or C.dim)
        end
        local s = self.rot_season[c.id]
        if s ~= nil then
            local good = (season ~= nil and c.seasons ~= nil
                          and c.seasons[season]) or false
            s:SetString(good and "当季" or "过季")
            SetColourOf(s, good and C.now or C.dim)
        end
    end

    -- ② 收起勾上的作物，算方案
    local ids = {}
    for _, c in ipairs(CROPS) do
        if self.rot_on[c.id] then table.insert(ids, c.id) end
    end

    if #ids == 0 then
        AddText(self.rot_root, PAD, -596,
            "先勾上作物（至少两种，一种跟自己抵消不了）。", 22, C.warn)
        return
    end

    local chains = FindChains(ids, season)

    if #chains == 0 then
        AddText(self.rot_root, PAD, -596,
            "这几样凑不出闭合的链：再勾一两样别的试试。", 22, C.warn)
        AddText(self.rot_root, PAD, -640,
            "（规律：得让三种养分被吃掉的总量一样多，才回得到原点）", 20, C.dim)
        return
    end

    -- ③ 列前 6 条。第一条是推荐（全当季 + 茬数少 + 水位高）
    local n = math.min(6, #chains)
    for i = 1, n do
        local ch = chains[i]
        local y  = -596 - (i - 1) * 44

        local parts = {}
        for _, id in ipairs(ch.chain) do
            table.insert(parts, PlantName(id))
        end

        -- ★ TALKINGFONT 里没有箭头字形，写「→」会渲染成问号 —— 用 ASCII 的 >
        AddText(self.rot_root, PAD, y,
            i .. ". " .. table.concat(parts, " > "), 26,
            (i == 1) and C.title or C.text)

        AddText(self.rot_root, 430, y,
            string.format("%d茬  水位%d  %s", #ch.chain, ch.low,
                ch.all_season and "全当季" or "含过季"),
            20, ch.all_season and C.now or C.warn)
    end
end

--──────────────────────────────────────────────────────────────────────────────
-- 按用户设的种子数量算布局。
-- 返回 rows（rows[r][c] = 作物 id，3 列）和 diag（诊断数据）；
-- 一个数量都没设时 rows 返回 nil。
--
-- ★★ v2.0.0 重写了缩放方向。上一版**方向是错的**：
--    它把用户输入当成「比例」，按比例放大到铺满整块地 ——
--    手里只有 1 个胡萝卜，也会给你排出 9 株。可输入框说的是「我手里有几个」，
--    面板却让你种 9 株，那是根本种不出来的。
--
--    现在改成：
--      · 有几种就摆几种，**只缩不放**；
--      · 总数没超过地皮格数 → 剩下的格子留空（画成暗底），一眼看出「还差几株」；
--      · 总数超过地皮格数 → 按比例缩到塞得下，并明确告诉你被缩了。
--
--    同时输出 diag —— 把上一版**完全漏掉的两项校验**摆到台面上：
--    养分三组是否配平、每种够不够 4 株（家族）。
--    上一版会画出一张「每种 3 株」（家族不足）或「-12 / 0 / +12」（严重失衡）的图，
--    然后一个字都不提醒 —— 它看起来像计算器，其实不做任何账。
--
-- ★ 番茄、西瓜（混合消耗型）不再被静默丢弃：它们照排进图里，
--   只是**不参与养分三组的配平**（净变化方向不唯一，放进「几株」里就没有唯一解），
--   诊断里单独说明。
--──────────────────────────────────────────────────────────────────────────────
--──────────────────────────────────────────────────────────────────────────────
-- 按你填的数量算布局 + 诊断（v2.6.0 重写）
--
--  新口径：找「一块地皮的零和配比」，每块照着种。
--    · **每块地皮自己零和** —— 养分按地皮记账，整片总和为零不算数
--    · **家族可以跨地皮凑** —— 少数派那种靠边界放（SearchTilePlan 的 blocks
--      就是按「每种凑够 4 株要几块」算出来的，能保证跨块也够）
--    · **每块 ≤ 10 株** —— 同 tile 拥挤上限
--  这三条同时满足时，模拟（_sim.py）跑出来是 100% 巨大、压力次数全 0。
--
--  返回 rows（画图用，3 列网格）+ diag（诊断）。
--──────────────────────────────────────────────────────────────────────────────

--──────────────────────────────────────────────────────────────────────────────
-- 逐株算家族：给定「每块的配比」和「要几块」，返回 (通过株数, 不合格株数)
--
-- ★ v2.6.9 从 BuildUserLayout 里抽出来，两页共用 ——
--   第一页图标注也要它：冬季那几个方案在九宫格下家族凑不满，
--   面板必须**如实标出来**，不能让人照着种还以为能成。
--
-- 几何：块内 3×3 九宫格（间距 TILL_SP = 1.25），多块时块心距 TILE_GAP = 4。
-- 摆位：同种连成一列；「需要跨块」的作物优先排到靠接缝那侧 ——
--       两块地皮的**同一列相距正好 4.0**，而判定是「小于 4」，那一列直接作废。
--
--   ★ 赋值式定义（上面有前置声明）—— 因为 RefreshPlan（1367 行）在它之前就调用了。
--──────────────────────────────────────────────────────────────────────────────
TileFamilyCount = function(items, blocks)
    local need_ids, ok_ids = {}, {}
    for _, it in ipairs(items) do
        if it.n < FAMILY_MIN then table.insert(need_ids, it.id)
        else table.insert(ok_ids, it.id) end
    end
    local order = {}
    for _, id in ipairs(need_ids) do table.insert(order, id) end
    for _, id in ipairs(ok_ids) do table.insert(order, id) end

    local flat = {}
    for _, id in ipairs(order) do
        for _, it in ipairs(items) do
            if it.id == id then
                for _ = 1, it.n do table.insert(flat, id) end
            end
        end
    end

    local COL_ORDER = { { 2, 1, 0 }, { 0, 1, 2 } }
    local pts = {}
    for b = 0, blocks - 1 do
        local bx = b * TILE_GAP
        local col_order = COL_ORDER[(b == blocks - 1) and 2 or 1]
        for idx = 1, #flat do
            local k = math.floor((idx - 1) / 3)
            local r = (idx - 1) % 3
            local c = col_order[k + 1] or 1
            table.insert(pts, { id = flat[idx], b = b, c = c, r = r,
                                x = bx + (c - 1) * TILL_SP,
                                z = (r - 1) * TILL_SP })
        end
    end

    local ok, bad = 0, 0
    for i = 1, #pts do
        local p, cnt = pts[i], 0
        for j = 1, #pts do
            if pts[j].id == p.id then
                local dx, dz = pts[j].x - p.x, pts[j].z - p.z
                if dx * dx + dz * dz < FAMILY_R * FAMILY_R then cnt = cnt + 1 end
            end
        end
        if cnt >= FAMILY_MIN then ok = ok + 1 else bad = bad + 1 end
    end
    return pts, ok, bad
end

function FarmHelperPanel:BuildUserLayout(counts)
    counts = counts or self.seed_counts

    local diag = {
        want      = 0,          -- 你填的总株数
        placed    = 0,          -- 方案实际要种的总株数
        truncated = false,      -- 是不是比你想种的少
        mixed     = {},         -- 凑不出配比时，用来提示「哪些是混合型」
        nutrient  = { 0, 0, 0 },
        net       = { 0, 0, 0 },
        balanced  = false,
        giants_ok = false,
        fam_pass  = 0,
        fam_fail  = 0,
        plan      = nil,        -- 命中的零和配比
        blocks    = 0,          -- 要几块地皮
        per_tile  = 0,          -- 每块地皮几株
        cross     = {},         -- 需要靠边界跨地皮凑家族的作物
    }

    -- ① 收集你手里的量
    local avail, total = {}, 0
    for _, crop in ipairs(CROPS) do
        local n = counts[crop.id] or 0
        avail[crop.id] = n
        total = total + n
    end
    diag.want = total
    if total == 0 then return nil, diag end

    -- ② 找「每块地皮的零和配比」
    local plan = SearchTilePlan(avail, TILE_MAX_MOUNDS)
    diag.plan = plan
    if plan == nil then
        -- 凑不出来：把「混合型」挑出来，好给一句有用的提示
        for _, crop in ipairs(CROPS) do
            if (avail[crop.id] or 0) > 0 then
                local d = NetDelta(crop.consume)
                local neg = 0
                for i = 1, 3 do if d[i] < 0 then neg = neg + 1 end end
                if neg >= 2 then table.insert(diag.mixed, crop.id) end
            end
        end
        return nil, diag
    end

    diag.blocks   = plan.blocks
    diag.per_tile = plan.total
    diag.placed   = plan.total * plan.blocks
    diag.truncated = diag.placed < total

    diag.balanced = true          -- 每块地皮自己零和 → 整片也就零和
    diag.net = { 0, 0, 0 }
    for _, it in ipairs(plan.items) do
        if it.n < FAMILY_MIN then table.insert(diag.cross, it.id) end
    end

    -- ③ 摆位 + 逐株真算家族
    --   ★ v2.6.8 把「写死合格」改成真算；v2.6.9 把这段几何抽成了
    --     `TileFamilyCount`，好让第一页的图标注也用它（冬季那几个方案
    --     在九宫格下家族凑不满，面板得如实标出来）。
    local pts, fam_pass, fam_fail = TileFamilyCount(plan.items, plan.blocks)
    diag.fam_pass, diag.fam_fail = fam_pass, fam_fail
    diag.giants_ok = (fam_fail == 0) and diag.placed > 0

    return pts, diag
end

function FarmHelperPanel:BuildUserLayoutLegacy(counts)
    -- ★ v2.4.1：接受外部数量表 —— 配平建议模式传 plan_counts，
    --   平时不传，用你自己填的 seed_counts。
    counts = counts or self.seed_counts
    local target = (self.tile_mode == 2) and 18 or 9

    local diag = {
        want      = 0,          -- 你设的总株数
        placed    = 0,          -- 实际排上图的株数
        truncated = false,      -- 是不是因为地皮不够被缩过
        mixed     = {},         -- 混合型作物（不参与养分计算）
        nutrient  = { 0, 0, 0 },-- 三组各自的总消耗点数
        net       = { 0, 0, 0 },-- 全图每阶段净变化（正 = 土壤净增）
        balanced  = false,
        giants_ok = false,
        fam_pass  = 0,          -- 几何判定：位置够家族的株数（这些能巨大）
        fam_fail  = 0,          -- 位置不够的株数（这些出不了巨大）
    }

    -- ① 收集。按「组」分桶：1~3 是三个养分轴，4 号桶留给混合型。
    local groups = { {}, {}, {}, {} }
    local total  = 0
    for _, crop in ipairs(CROPS) do
        local n = counts[crop.id] or 0
        if n > 0 then
            local g = CropGroup(crop)
            table.insert(groups[g or 4], { id = crop.id, n = n })
            total = total + n
            if g == nil then
                table.insert(diag.mixed, crop.id)
            end
        end
    end
    diag.want = total
    if total == 0 then return nil, diag end

    -- ② 缩放到地皮塞得下。★ 只缩不放。
    local alloc = {}
    if total <= target then
        for s = 1, 4 do
            for _, e in ipairs(groups[s]) do
                table.insert(alloc, { id = e.id, k = e.n })
            end
        end
        diag.placed = total
    else
        -- 塞不下：按比例缩。余数按「小数部分大的先补」，比从头轮流补更接近原比例。
        local acc, fracs, used = {}, {}, 0
        for s = 1, 4 do
            for _, e in ipairs(groups[s]) do
                local exact = e.n * target / total
                local k = math.floor(exact)
                table.insert(acc, { id = e.id, k = k })
                table.insert(fracs, { idx = #acc, frac = exact - k })
                used = used + k
            end
        end
        table.sort(fracs, function(a, b)
            if a.frac == b.frac then return a.idx < b.idx end
            return a.frac > b.frac
        end)
        local i = 1
        while used < target and #fracs > 0 do
            acc[fracs[i].idx].k = acc[fracs[i].idx].k + 1
            used = used + 1
            i = i % #fracs + 1
        end
        for _, e in ipairs(acc) do
            if e.k > 0 then table.insert(alloc, e) end
        end
        diag.truncated = true
        diag.placed = target
    end

    -- ③ 摊平。顺序就是组的顺序 —— 同种作物天然连成一整块，
    --    这正是家族要求想要的排法（同种 ≥4 株、判定是半径 4 的圆形搜索，
    --    连成一块时最远两株的距离远小于 4）。
    local flat = {}
    for _, e in ipairs(alloc) do
        for _ = 1, e.k do table.insert(flat, e.id) end
    end

    -- ④ 按 3 列切行
    local rows, row = {}, nil
    for idx = 1, #flat do
        if (idx - 1) % 3 == 0 then
            row = {}
            table.insert(rows, row)
        end
        row[#row + 1] = flat[idx]
    end

    -- ④⑤ 家族按**几何**判（v2.2.0 重写）。
    --
    --   旧版只查「每种总数 ≥4」—— 这是错的。游戏里的检查是
    --   每株在半径 4 内数同种（farm_plants.lua:178-181 FindEntities），
    --   半径 4 恰好够到上下左右 4 个邻格、够不到斜角（4.0 vs 5.7），
    --   所以每株要凑「自己 + 3 个同种邻居」；总数再多，摆得散也白搭。
    local fam_pass, fam_fail = 0, 0
    for r = 1, #rows do
        for c = 1, #rows[r] do
            local id = rows[r][c]
            if id ~= nil then
                local same = 0
                if r > 1 and rows[r - 1][c] == id then same = same + 1 end
                if r < #rows and rows[r + 1][c] == id then same = same + 1 end
                if c > 1 and rows[r][c - 1] == id then same = same + 1 end
                if c < #rows[r] and rows[r][c + 1] == id then same = same + 1 end
                if same + 1 >= FAMILY_MIN then
                    fam_pass = fam_pass + 1
                else
                    fam_fail = fam_fail + 1
                end
            end
        end
    end
    diag.fam_pass, diag.fam_fail = fam_pass, fam_fail

    -- ⑥ 诊断一：养分三组的总消耗点数，相等才算配平
    for _, e in ipairs(alloc) do
        local crop = CropById(e.id)
        if crop ~= nil then
            local d = NetDelta(crop.consume)
            for i = 1, 3 do
                if d[i] < 0 then
                    diag.nutrient[i] = diag.nutrient[i] + (-d[i]) * e.k
                end
            end
        end
    end
    diag.balanced = (diag.nutrient[1] == diag.nutrient[2])
                and (diag.nutrient[2] == diag.nutrient[3])

    -- ⑤' 全图「每阶段净变化」（v2.3.0：诊断行「需补肥料」的数据源）
    diag.net = { 0, 0, 0 }
    for _, e in ipairs(alloc) do
        local crop = CropById(e.id)
        if crop ~= nil then
            local d = NetDelta(crop.consume)
            for i = 1, 3 do
                diag.net[i] = diag.net[i] + d[i] * e.k
            end
        end
    end

    -- ⑥ 总判定：养分配平 + 每一株都凑齐家族，才有「全部巨大」可言
    diag.giants_ok = diag.balanced and fam_fail == 0 and diag.placed > 0

    return rows, diag
end

-- 重画示意图 + 图例 + 诊断
--
-- ★ v2.0.0：格子内容从「纯色方块」换成**游戏自带的作物图标**
--   （GetInventoryItemAtlas 取，不用自己画贴图），颜色降级成格子底色 ——
--   图标负责「是什么」，底色负责「属于哪一组」，两个信息都不丢。
--
--   底部新增两行诊断，把这一页之前**完全没算过的账**补上：
--   养分三组是否配平、每种够不够 4 株。上一版会画出严重失衡的图却一声不吭。
function FarmHelperPanel:RefreshDemo()
    if self.demo_root == nil then return end
    self.demo_root:KillAllChildren()
    self.legend_root:KillAllChildren()
    self.diag_root:KillAllChildren()

    local pts, diag = self:BuildUserLayout(self.plan_counts)

    -- ★ v2.4.1 建议模式提示：示意图现在画的是「配平建议」，
    --   你填的数量没被动过；手动改任意数量即退出建议模式。
    if self.plan_counts ~= nil then
        AddText(self.demo_root, 168, -716,
            "（配平建议，你填的数量没动；手动改数量即退出）", 20, C.dim)
    end

    -- ★ v2.6.8：地皮数不再由用户选（那个「3x3 / 3x3 x2」按钮已删 —— 算法不读它，
    --   按它画图会出现「一块满、一块永远空着」的假象），改成画 diag.blocks 块，
    --   每块一个 3×3 九宫格，块间留 60px。
    local cell = 30
    local x0, y0 = 78, -758
    local BLOCK_W = cell * 3 + 60

    local nb = (pts ~= nil) and diag.blocks or 2
    for b = 0, nb - 1 do
        for slot = 1, 9 do
            local c = (slot - 1) % 3
            local r = math.floor((slot - 1) / 3)
            local blank = self.demo_root:AddChild(Image("images/global.xml", "square.tex"))
            blank:SetSize(cell - 6, cell - 6)
            blank:SetPosition(x0 + b * BLOCK_W + c * cell, y0 - r * cell, 0)
            blank:SetTint(1, 1, 1, 0.05)
        end
    end

    if pts == nil then
        -- ★ 区分「什么都没设」和「只设了混合型作物」——
        --   上一版对后者也说「先把数量加上去」，可用户明明已经加了。
        if #diag.mixed > 0 then
            local names = {}
            for _, id in ipairs(diag.mixed) do
                table.insert(names, PlantName(id))
            end
            AddText(self.legend_root, 300, -768,
                table.concat(names, "、") .. " 是混合消耗型（同时吃两种养分）", 24, C.warn)
            AddText(self.legend_root, 300, -808,
                "再加几种单一消耗型的作物，就能算出摆法。", 24, C.warn)
        else
            AddText(self.legend_root, 300, -768,
                "先把上面某几种的数量加上去（点 - 和 +）", 26, C.warn)
        end
        return
    end

    -- 相邻两块之间画一条竖分隔线，免得看成一块连着的 6×3 地
    for b = 1, nb - 1 do
        local line = self.demo_root:AddChild(Image("images/global.xml", "square.tex"))
        line:SetSize(2, cell * 3)
        line:SetPosition(x0 + b * BLOCK_W - cell * 1.5, y0 - cell, 0)
        line:SetTint(1, 1, 1, 0.22)
    end

    -- 按 pts 画（pts 里带块号 / 列 / 行）
    for _, p in ipairs(pts) do
        local cx = x0 + p.b * BLOCK_W + p.c * cell
        local cy = y0 - p.r * cell
        local col = CropColour(p.id)
        local sq = self.demo_root:AddChild(Image("images/global.xml", "square.tex"))
        sq:SetSize(cell - 4, cell - 4)
        sq:SetPosition(cx, cy, 0)
        -- 底色压暗一档，别把图标本身的颜色盖掉
        sq:SetTint(col[1] * 0.5, col[2] * 0.5, col[3] * 0.5, 0.9)
        AddItemIcon(self.demo_root, p.id, ".tex", cx, cy, cell - 12)
    end

    -- 图例：只列出现在图里的作物。★ v2.6.8 报的是「**每块几株**」而不是总数 ——
    -- 总数里带着 N 块的总和，照着种的时候看的是每块那个数。
    local cnt, order, seen = {}, {}, {}
    for _, p in ipairs(pts) do
        cnt[p.id] = (cnt[p.id] or 0) + 1
        if not seen[p.id] then
            seen[p.id] = true
            table.insert(order, p.id)
        end
    end

    -- 排两列（单列 6 项会一路撞到下面的说明行和诊断行 —— _layout.py 抓到过）
    local LEG_X = x0 + nb * BLOCK_W + 20
    local MAX_LEGEND = 6
    for i, id in ipairs(order) do
        local lx = LEG_X + ((i - 1) % 2) * 300
        local ly = -764 - math.floor((i - 1) / 2) * 36
        if i > MAX_LEGEND then
            AddText(self.legend_root, lx, ly,
                "还有 " .. tostring(#order - MAX_LEGEND) .. " 种", 22, C.dim)
            break
        end
        local col = CropColour(id)
        local dot = self.legend_root:AddChild(Image("images/global.xml", "square.tex"))
        dot:SetSize(30, 30)
        dot:SetPosition(lx + 15, ly, 0)
        dot:SetTint(col[1] * 0.5, col[2] * 0.5, col[3] * 0.5, 0.9)
        AddItemIcon(self.legend_root, id, ".tex", lx + 15, ly, 24)
        AddText(self.legend_root, lx + 36, ly,
            string.format("%s 每块 %d 株", PlantName(id),
                math.floor((cnt[id] or 0) / math.max(1, nb))), 22, C.text)
    end

    -- 诊断行一：养分三组的总消耗点数（v2.4.0：-900 → -936，随示意图下移）
    local ny = -948
    -- ★ v2.6.0：养分按**地皮**记账 —— 所以看的不是「整片三组是否相等」，
    --   而是「**每块地皮自己**是否零和」。SearchTilePlan 命中的方案天然零和。
    local ntxt
    if diag.plan == nil then
        ntxt = "配比　手里的作物凑不出每块地皮的零和组合"
    else
        local parts = {}
        for _, it in ipairs(diag.plan.items) do
            table.insert(parts, string.format("%s %d", PlantName(it.id), it.n))
        end
        ntxt = string.format("每块地皮 %d 株：%s ×%d",
            diag.per_tile, table.concat(parts, " + "), diag.blocks)
    end
    AddText(self.diag_root, PAD, ny, ntxt, 24,
        diag.plan ~= nil and C.plus or C.minus)

    -- 诊断行二：家族 —— 按每株的**几何位置**判（v2.2.0 重写）
    -- 游戏的检查是每株在半径 4（恰好一格，斜角不算）内找同种，
    -- 要凑「自己 + 3 个同种邻居」；所以角上的格子天生过不了。
    -- ★ v2.6.0：家族改成「密排 + 可跨地皮」的口径 ——
    --   同种 ≥4 株挤成一堆就行（块内对角 3.54）；凑不满 4 株的那种，
    --   靠地皮边界放、跟隔壁那块的同种挨上（贴边距离 1.5，也在半径 4 内）。
    local ftxt
    if diag.plan == nil then
        ftxt = "家族　等有了能配平的组合再算"
    elseif #diag.cross > 0 then
        local names = {}
        for _, id in ipairs(diag.cross) do
            table.insert(names, PlantName(id))
        end
        ftxt = string.format("家族　%s 靠地皮边界放，跟隔壁那块凑够 4 株",
            table.concat(names, "、"))
    else
        ftxt = string.format("家族　%d 株全部合格（同种 4 株挤一堆）", diag.fam_pass)
    end
    AddText(self.diag_root, PAD, ny - 32, ftxt, 24,
        (diag.fam_fail == 0) and C.plus or C.minus)

    -- 诊断行三（常驻）：巨大的第二个硬条件 + 还需要玩家做的两件事
    -- ★★★ v2.6.7 删掉了这里一整段「需补肥料」的死计算：
    --   它按 `diag.net` 算全季缺口、再拿 `self.fert_counts` 抵，算出一个 `verdict`
    --   —— 而这三样全是死的：`diag.net` 在新路径里被写死成 {0,0,0}
    --   （因为方案本来就是零和配比），`fert_counts` 已随肥料库存 UI 一起删，
    --   `verdict` 算出来从来没被打印过。真正上屏的一直是下面这句硬编码文案。
    --   独立审查的原话：这类「不报错、不影响加载、看着一切正常」的失效最难发现。
    -- ★ 巨大的第二个硬条件：薇克巴顿的书催熟 = no_oversized 一票否决
    --   （farm_plants.lua:596 → :518）—— 压力再低也出不了巨大。
    AddText(self.diag_root, PAD, ny - 64,
        "施肥　每块地皮自己收支相抵 → 一季不用施肥（每阶段浇一次水、长草就拔）",
        22, C.note)

    -- 说明行（图右侧空当，有话才说）：被缩过 / 混合型，合成一行短句
    local extra = {}
    if diag.truncated then
        table.insert(extra, string.format("方案只用 %d 株（你填了 %d 株，多的留着）",
            diag.placed, diag.want))
    end
    if #diag.mixed > 0 then
        local names = {}
        for _, id in ipairs(diag.mixed) do
            table.insert(names, PlantName(id))
        end
        table.insert(extra, table.concat(names, "、") .. "为混合型")
    end
    if #extra > 0 then
        AddText(self.diag_root, 300, -900, table.concat(extra, "；"), 22, C.note)
    end
end

-- 这一帧鼠标是不是压在某个按钮上（拖拽要避开按钮，否则点按钮会顺带把面板拖走）
function FarmHelperPanel:IsOverAnyButton(mx, my)
    local list = self.buttons[self.cur_page]
    if list == nil then return false end

    -- 优先问引擎：InvisibleButton 拿到焦点，就说明鼠标正压在它上面。
    -- 这比我们自己算坐标准（引擎用的是它内部那套屏幕坐标）。
    for _, b in ipairs(list) do
        if b.hit ~= nil and b.hit.focus then
            return true
        end
    end

    -- 备用：万一焦点没接上，自己粗算一遍。
    -- 宁可误判成「在按钮上」（不拖面板），也别把点击当成拖动。
    local ox, oy, s = self:ScreenOrigin()
    for _, b in ipairs(list) do
        local sx = ox + b.origin_x * s
        local sy = oy + b.origin_y * s
        local hw, hh = b.hit_w * 0.5 * s, b.hit_h * 0.5 * s
        if mx >= sx - hw and mx <= sx + hw and my >= sy - hh and my <= sy + hh then
            return true
        end
    end
    return false
end

-- 点击和悬停高亮都已经交给引擎的 InvisibleButton 了（见 AddButton）。
-- 这里只留一段诊断：左键刚按下时把各按钮的焦点状态打出来。
-- 以后万一又点不动，一眼就能分清是「焦点没接上」还是「回调没触发」。
local BTN_DIAG_LEFT = 12

function FarmHelperPanel:UpdateButtons()
    local list = self.buttons[self.cur_page]
    if list == nil or #list == 0 then return end

    local down = TheInput:IsMouseDown(MOUSEBUTTON_LEFT)
    if down and not self.mouse_was_down and BTN_DIAG_LEFT > 0 then
        BTN_DIAG_LEFT = BTN_DIAG_LEFT - 1
        local st = {}
        for _, b in ipairs(list) do
            if b.hit == nil then
                table.insert(st, "nil")
            else
                table.insert(st, b.hit.focus and "focus" or "-")
            end
        end
        print(string.format("[FarmHelper] 左键按下 · 第 %d 页 · %d 个按钮焦点: %s",
            self.cur_page, #list, table.concat(st, " ")))
    end
    self.mouse_was_down = down
end

--==============================================================================
--  七、拖动
--==============================================================================

-- 面板当前的 UI 缩放系数。鼠标坐标是真实屏幕像素，所以把像素位移换算成
-- 面板本地单位时要除掉这个系数（HUD 缩放不为 1 时才起作用，平时就是 1）。
--
-- ★ 这里每一步都得挡。取值链是：
--     Widget:GetWorldScale()            (widget.lua:348-350)
--       → Vector3(self.inst.UITransform:GetWorldScale())
--   主菜单里给角色预览用的那个 controls 上，UITransform 的 GetWorldScale
--   根本不存在，调用直接抛
--     "attempt to call method 'GetWorldScale' (a nil value)"
--   —— 一个纯显示面板把整个游戏带崩很不值，所以宁可拿不到就按 1 算。
function FarmHelperPanel:UIScale()
    local inst = self.inst
    if inst == nil or inst.UITransform == nil then
        return 1
    end

    local ok, v = pcall(self.GetWorldScale, self)
    if not ok or v == nil or v.x == nil then
        return 1
    end

    -- 万一拿到明显不合理的值也按 1 处理，别让拖动速度失控。
    if v.x < 0.2 or v.x > 5 then
        return 1
    end
    return v.x
end

-- ★ v2.2.1：不带任何钳制的世界缩放，专供自动缩放用。
--   UIScale() 的「<0.2 按 1 算」兜底是用来保护拖动速度的，但它会**骗人**：
--   自动缩放拿它反推父级缩放时，一旦整块缩到 0.2 以下，反推出的父级缩放
--   被放大 1/fit 倍 → 算出更小的 fit → 世界缩放更小 → 兜底再触发……
--   每帧乘一个更小的系数，就是用户看到的「一开始很大，然后一直缩小」。
--   反馈回路里必须用真实值，钳制只能放在回路外面。
function FarmHelperPanel:RawWorldScale()
    local inst = self.inst
    if inst == nil or inst.UITransform == nil then
        return 1
    end

    local ok, v = pcall(self.GetWorldScale, self)
    if not ok or v == nil or v.x == nil then
        return 1
    end
    return v.x
end

-- 面板左上角在屏幕上的像素位置。
-- 鼠标坐标与 GetWorldPosition() 是同一个坐标系 —— 游戏自己的
-- widgets/mousetracker.lua 就是拿这两个直接相减的。
function FarmHelperPanel:ScreenOrigin()
    local s = self:UIScale()
    local w, h = TheSim:GetScreenSize()

    -- 正常情况直接问引擎。GetWorldPosition() 和 UIScale 一样，内部也是走
    -- inst.UITransform 的（widget.lua:344-346），环境不完整时同样会抛错，
    -- 所以这里也挡一层；拿不到就退回「锚在屏幕左上」那套换算：
    -- 本地 x 就是屏幕 x，本地 y 从屏幕顶往下数，对应的屏幕 y 是 h + panel_y。
    local ok, p = pcall(self.GetWorldPosition, self)
    if ok and p ~= nil
       and p.x >= -PANEL_W * 2 and p.x <= w + PANEL_W * 2
       and p.y >= -PANEL_H * 2 and p.y <= h + PANEL_H * 2 then
        return p.x, p.y, s
    end

    return self.panel_x * s, h + self.panel_y * s, s
end

-- 面板顶边允许贴到屏幕顶往下多少（避免标题栏被裁掉一条边）
local EDGE_KEEP = 8

-- 把面板挪到本地坐标 (x, y) 并做钳制。
--
-- 锚点是「屏幕左上」，所以本地 x 向右为正、本地 y 向下为负：
-- 面板占 [x, x + PANEL_W*s] × [y - PANEL_H*s, y]（本地）。
-- 换成屏幕像素（原点在左下、y 朝上）：顶边 = h + y*s，底边 = h + y*s - PANEL_H*s。
--
-- ★★ v2.1.0 改了纵向钳制 —— 这就是「拖拽没有合理运作」的另一半原因。
--   以前要求「整块面板都在屏幕里」，可面板 1010×1025、屏幕 1920×1080，
--   纵向只剩 1080-1025 = **55px** 的活动余量，拖起来跟卡死一样，
--   横向能挪纵向挪不动，看起来就是「拖拽坏了」。
--   现在只保证**标题栏始终在屏幕内**：想拖多远拖多远，但抓手永远看得见、
--   抓得回来，另有「复位」按钮和右键兜底。
--
--   横向仍然要求整块在屏幕里 —— 面板宽 1010，在 1920 上本来就有 910px 可挪。
--
-- 只用屏幕尺寸和本地坐标推算，不去读 GetWorldPosition()，
-- 免得坐标换算出问题时把面板推到看不见的地方。
function FarmHelperPanel:MoveTo(x, y)
    local s  = self:UIScale()
    local w, h = TheSim:GetScreenSize()
    local pw = PANEL_W * s

    -- 横向：面板占 [x, x+pw]，要求 0 <= x 且 x+pw <= w
    if pw <= w then
        x = math.max(0, math.min(w - pw, x))
    else
        x = math.max(w - pw, math.min(0, x))   -- 比屏幕宽：左右都能推出去，但别推光
    end

    -- 纵向：顶边不许高过屏幕顶（y <= 0）；
    --       标题栏底边不许低于屏幕底再留 EDGE_KEEP：
    --         h + y*s - GRIP_H*s >= EDGE_KEEP  →  y >= GRIP_H + (EDGE_KEEP - h)/s
    local y_min = GRIP_H + (EDGE_KEEP - h) / s
    y = math.max(y_min, math.min(0, y))

    self.panel_x, self.panel_y = x, y
    self:SetPosition(x, y, 0)

    -- 只在第一次打印一次，方便排查「面板位置/尺寸不对」这类问题
    if not self.logged_pos then
        self.logged_pos = true
        print(string.format(
            "[FarmHelper] 屏幕 %dx%d，面板 %.0fx%.0f（缩放 %.2f），落点 (%.0f, %.0f)，纵向可拖 %.0fpx",
            w, h, pw, PANEL_H * s, s, x, y, -y_min))
    end
end

-- 回到默认位置（左上角，整块都看得见）
function FarmHelperPanel:ResetPos()
    self:MoveTo(HOME_X, HOME_Y)
    SavePos(self.panel_x, self.panel_y)
    print(string.format("[FarmHelper] 复位到 (%.0f, %.0f)", self.panel_x, self.panel_y))
end

-- 鼠标是不是压在标题栏上。
-- ★ v2.1.0：优先问引擎的焦点系统（grip_hit 是引擎自己判定的，坐标一定对得上）；
--   拿不到手柄节点时才退回自己算坐标。
function FarmHelperPanel:IsOverGrip(mx, my)
    if self.grip_hit ~= nil then
        -- 压在按钮上时不算抓手 —— 否则点一下按钮会顺带把面板拖走
        if self:IsOverAnyButton(mx, my) then
            return false
        end
        return self.grip_hit.focus == true
    end

    local ox, oy, s = self:ScreenOrigin()
    return mx >= ox and mx <= ox + PANEL_W * s
       and my <= oy and my >= oy - GRIP_H * s
end

-- 标题栏的明暗：平时淡、悬停亮一点、按住最亮 —— 让人知道这里能抓
function FarmHelperPanel:GripGlow(alpha)
    if self.grip_bg ~= nil then
        self.grip_bg:SetTint(1, 1, 1, alpha)
    end
end

function FarmHelperPanel:UpdateDrag()
    if not self:IsVisible() then
        DRAG.active = false
        return
    end

    local mx, my = TheInput:GetScreenPosition():Get()
    local hold_left  = TheInput:IsMouseDown(MOUSEBUTTON_LEFT)
    local hold_right = TheInput:IsMouseDown(MOUSEBUTTON_RIGHT)
    local in_grip    = self:IsOverGrip(mx, my)

    -- 左键刚按下时打一条诊断（只打前几次）：把鼠标位置、引擎给的面板原点、
    -- 手柄焦点状态全都列出来。以后再出现「按下没反应 / 拖不动」，
    -- 一眼就能分清是命中判定错、还是坐标换算错、还是根本没进 UpdateDrag。
    if hold_left and not self.was_left_down and DRAG_DIAG_LEFT > 0 then
        DRAG_DIAG_LEFT = DRAG_DIAG_LEFT - 1
        local ox, oy = self:ScreenOrigin()
        print(string.format(
            "[FarmHelper] 左键按下 · 鼠标 (%.0f, %.0f) · 面板原点 (%.0f, %.0f) · 手柄焦点 %s · 判为抓手 %s",
            mx, my, ox, oy,
            self.grip_hit ~= nil and tostring(self.grip_hit.focus) or "无手柄",
            tostring(in_grip)))
    end

    if DRAG.active then
        if hold_left then
            -- 按下之后面板跟着鼠标走。记录的是「按下那一刻」的鼠标位置和面板位置，
            -- 所以只用**位移量**，跟坐标系原点在哪儿无关 —— 这是最稳的一种算法。
            local s = self:UIScale()
            self:MoveTo(DRAG.px + (mx - DRAG.mx) / s,
                        DRAG.py + (my - DRAG.my) / s)
            return
        end
        -- 松手：收工，把位置记下来
        DRAG.active = false
        SavePos(self.panel_x, self.panel_y)
        self:GripGlow(in_grip and 0.16 or 0.06)
    else
        -- 只在「刚在标题栏上按下」的那一刻才开始拖。
        -- 否则拖着别的界面（比如背包里的物品）路过面板，面板会被顺手带走。
        if in_grip and hold_left and not self.was_left_down then
            DRAG.active = true
            DRAG.mx, DRAG.my = mx, my
            DRAG.px, DRAG.py = self.panel_x, self.panel_y
            self:GripGlow(0.20)
        elseif in_grip and hold_right then
            -- 右键标题栏 = 复位。按住不放只复位一次。
            if not DRAG.latched then
                DRAG.latched = true
                self:ResetPos()
            end
        else
            DRAG.latched = false
            self:GripGlow(in_grip and 0.14 or 0.06)
        end
    end

    self.was_left_down = hold_left
end

--==============================================================================
--  八、每帧更新
--==============================================================================

function FarmHelperPanel:OnUpdate(dt)
    -- 不在世界里就什么都不做。
    -- DST 主菜单为了角色预览也会构造一次 controls，我们的 postinit 会在那上面
    -- 也挂一个面板出来 —— 那时候既没有季节也没有可拖的东西，而且那套 UI 环境
    -- 不完整（问缩放会直接抛错）。直接跳过的成本几乎为零。
    if GLOBAL.TheWorld == nil then
        -- 顺手确保它是收起的：用户若在设置里选了「自动展开」，主菜单那个
        -- 面板会露在角色预览上。进世界后 HUD 会重建，新面板再按设置决定。
        if self:IsVisible() then
            self:Hide()
        end
        return
    end

    -- ★ v2.2.1 自动缩放（修复 v2.2.0 的「越缩越小」死亡螺旋）：
    --   旧实现拿 UIScale() 反推父级缩放，但 UIScale() 有个「世界缩放 <0.2 按 1 算」
    --   的兜底 —— 整块一旦缩过阈值，反推出的父级缩放被放大 1/fit 倍，
    --   算出的 fit 更小 → 世界缩放更小 → 兜底再触发……每帧乘一个更小的系数。
    --   三重修复：
    --     ① 反馈回路改用不带钳制的 RawWorldScale()；
    --     ② 只在窗口尺寸变化（或首次）时重算，不做每帧连乘；
    --     ③ 缩放下限 0.6 —— 宁可底部出屏（还有复位按钮），也不缩成蚂蚁字。
    --   另外注意：HUD 根本来就是**等比缩放**（窗口多小 HUD 就多小），
    --   所以正常情况下这里的 fit 恒等于 1，真正缩小只发生在极端窗口比例。
    local scr_w, scr_h = TheSim:GetScreenSize()
    if self.fit_scale == nil
       or self.fit_checked_w ~= scr_w or self.fit_checked_h ~= scr_h then
        self.fit_checked_w, self.fit_checked_h = scr_w, scr_h

        local root_s = self:RawWorldScale() / (self.fit_scale or 1)
        local fit = math.min(1, (scr_h - 24) / (PANEL_H * root_s),
                                (scr_w - 24) / (PANEL_W * root_s))
        fit = math.max(fit, 0.6)

        if math.abs(fit - (self.fit_scale or 1)) > 0.002 then
            self.fit_scale = fit
            self:SetScale(fit, fit, 1)
            print(string.format(
                "[FarmHelper] 屏幕 %dx%d、HUD 缩放 %.2f → 面板整块 ×%.2f（显示 %.0fx%.0f）",
                scr_w, scr_h, root_s, fit, PANEL_W * root_s * fit, PANEL_H * root_s * fit))
        end
    end

    -- 位置存档是异步读的，读到之后套用一次。
    -- ★ 这里不能加 IsVisible() 条件 —— 面板默认收起时，那次 Show() 之前
    --   位置永远不会被应用，用户会觉得「位置记不住」。
    RequestSavedPos()
    if POS.x ~= nil and not self.pos_applied then
        self.pos_applied = true
        self:MoveTo(POS.x, POS.y)
        -- 读回来的坐标如果被钳制纠正过（典型情况：上次把面板拖出屏幕，
        -- 存档里存的就是屏幕外的值），立刻写回，免得每次都再纠一遍。
        SavePos(self.panel_x, self.panel_y)
    end

    self:UpdateDrag()
    self:UpdateButtons()

    -- 季节变了就刷新高亮，同时更新那一行文字
    local season, days = GetSeason()
    if season ~= self.last_season then
        self:RefreshRows()
    end

    local season_cn = season ~= nil and SEASON_CN[season] or "?"
    local str = string.format("当前季节：%s", season_cn)
    if days ~= nil then
        -- ★ remainingdaysinseason 是浮点数（剩 19.6 天这种）。
        --   用 ceil 而不是 floor(x+0.5)：剩 19.6 天时说「还剩 20 天」
        --   更符合直觉（这一整天还没过完），也免得 19.5 上下反复跳字。
        str = string.format("%s    还剩 %d 天", str, math.ceil(days))
    end
    if self.season_text:GetString() ~= str then
        self.season_text:SetString(str)
    end

    -- 诊断：天数每变一次打一行（带上原始浮点值，方便和游戏里的季节钟核对）
    if days ~= nil and math.floor(days) ~= self.last_days_log then
        self.last_days_log = math.floor(days)
        print(string.format("[FarmHelper] 季节 %s · 剩余天数 raw=%.3f → 面板显示 %d",
            tostring(season), days, math.ceil(days)))
    end
end

--==============================================================================
--  九、挂到 HUD 上 + 绑定快捷键
--==============================================================================

-- 面板挂在 widgets/controls 上（见下面的 AddClassPostConstruct），
-- 而 controls 是 HUD 的子节点 —— playerhud.lua:923 那句
--     self.controls = self.root:AddChild(Controls(self.owner))
-- 所以取面板必须走 HUD.controls.farmhelper_panel。
--
-- 1.3.2 及之前这里写的是 player.HUD.farmhelper_panel，那个字段从来就不存在，
-- 于是每次按键都在下面那行判断上静默 return：不报错，也不显示。
--
-- ThePlayer / TheWorld 用 GLOBAL. 前缀取：GLOBAL 是 env 白名单里的键，必定有效，
-- 不依赖第 0 节那个 __index 兜底（这两个在主菜单里本来就是 nil，
-- 也不能放进加载期的自检名单）。
local announced_panel = false
local warned_no_panel = false

-- 取面板。挂在 HUD.controls 上，所以必须走同一条路取回来
-- （写成 ThePlayer.HUD.farmhelper_panel 会是永远 nil，而且不报错 —— 见 README 那个坑）。
local function GetPanel()
    if GLOBAL.ThePlayer == nil or GLOBAL.ThePlayer.HUD == nil then return nil end

    local controls = GLOBAL.ThePlayer.HUD.controls
    local panel = controls ~= nil and controls.farmhelper_panel or nil
    if panel == nil and not warned_no_panel then
        warned_no_panel = true
        print("[FarmHelper] 按键触发了，但 HUD.controls 上没有面板 —— 面板没挂上")
    end
    return panel
end

-- 开关面板
local function TogglePanel()
    local panel = GetPanel()
    if panel == nil then return end

    if panel:IsVisible() then
        panel:Hide()
    else
        panel:Show()
        panel:RefreshRows()
    end
end

-- 切页键。
--   面板没开 → 打开面板并直接停在第二页（「按一下就到第二页」）
--   在第一页 → 切到第二页
--   在第二页 → 切回第一页（方便来回对照）
local function SwitchPanelPage()
    local panel = GetPanel()
    if panel == nil then return end

    if not panel:IsVisible() then
        panel:Show()
        panel:RefreshRows()
        panel:SwitchPage(2)
    else
        -- v2.5.0：三页轮流（信息 → 种植 → 轮作 → 信息）
        panel:SwitchPage(panel.cur_page % 3 + 1)
    end
end

AddClassPostConstruct("widgets/controls", function(self, owner)
    self.farmhelper_panel = self:AddChild(FarmHelperPanel(owner))
    if not announced_panel then
        announced_panel = true
        print("[FarmHelper] 面板已挂到 HUD controls 上")
    end
end)

if TheInput ~= nil then
    TheInput:AddKeyDownHandler(OPEN_KEY, TogglePanel)
    -- 两个键设成同一个的话，H 会同时开关+切页，直接跳过切页更安全
    if PAGE_KEY ~= OPEN_KEY then
        TheInput:AddKeyDownHandler(PAGE_KEY, SwitchPanelPage)
    else
        print("[FarmHelper] 切页键和开关键是同一个，已跳过切页键注册")
    end
end

--══════════════════════════════════════════════════════════════════════════
-- ★★★ v2.6.6：四季配比「运行期自检」
--
--  为什么要有这个 —— v2.6.0 的 FindUnitPlan **漏了零和检查**（定义了 zero()
--  却没在 consider 里调用），于是面板上出现了「胡萝卜 + 洋葱」：
--  两个都吃生长素的单轴作物，净变化相加永远不可能为 0。
--
--  它为什么能活好几天没被发现（三条同时成立）：
--    ① 面板上它就是一行文字，不像崩溃那样扎眼 —— 而我这几天改的全是
--       它**周围**的东西（图、说明、字号、冬季方案），一次都没读过它本身的输出；
--    ② luacheck 查不出 —— luaparser 只验语法，不管「定义了但没调用」；
--    ③ 离线的 `_plan.py` 是**另一份实现**、自带零和检查，所以模拟一直是对的，
--       我拿模拟结果当证据，却没拿它和面板的真实输出对过账。
--
--  所以这里加一道运行期自检：加载时把四季配比算一遍、验证零和、打进日志。
--  以后「打开日志就能核对面板上的四季推荐」。
--══════════════════════════════════════════════════════════════════════════
local function SelfCheckPlans()
    local all_ok = true
    for _, s in ipairs(SEASON_ORDER) do
        local p = FindUnitPlan(s)
        if p == nil then
            all_ok = false
            print(string.format("[FarmHelper] 自检 %s：没算出配比", SEASON_CN[s]))
        else
            local sum = { 0, 0, 0 }
            for _, it in ipairs(p.items) do
                local d = NetDelta(CropById(it.id).consume)
                for i = 1, 3 do sum[i] = sum[i] + d[i] * it.n end
            end
            local bad = math.abs(sum[1]) > 0.001
                     or math.abs(sum[2]) > 0.001
                     or math.abs(sum[3]) > 0.001
            if bad then all_ok = false end
            local parts = {}
            for _, it in ipairs(p.items) do
                table.insert(parts, string.format("%s %d", PlantName(it.id), it.n))
            end
            print(string.format("[FarmHelper] 自检 %s：每块 %d 株（%s）× %d 块 → %s",
                SEASON_CN[s], p.total, table.concat(parts, " + "), p.blocks,
                bad and "零和失败，算法有 bug！" or "零和 OK"))
        end
    end
    return all_ok
end

local selfcheck_ok = SelfCheckPlans()

print(string.format("[FarmHelper] modmain 加载完成：%s 开关 / %s 切页",
    tostring(KEY_HINT), tostring(PAGE_HINT)))
