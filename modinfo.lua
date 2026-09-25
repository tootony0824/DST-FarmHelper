name = "农事手册 (Farm Helper)"
description = "按 H 打开种地信息面板，告诉你这个季节种什么、每块地皮几株、怎么摆。\n\n【信息】\n· 四季推荐：当前季高亮，每季列出前 3 个配比方案 + 摆法图\n  春/秋 4 番茄 + 4 土豆（1 块）｜夏 6 番茄 + 3 火龙果（2 块）｜冬 3 南瓜 + 3 芦笋 + 3 土豆（2 块）\n  三条规则全部来自游戏源码考证（养分按地皮记账 / 家族半径 4 可跨地皮 / 同地皮不超过 10 株），\n  并与灰机 wiki、英文 wiki、Steam 社区指南交叉验证一致\n· 14 种作物的「作物名 / 种子名」对照，两边都带图标——种子是按形状起名的，\n  光看名字认不出长成什么，这张表就是干这个的\n· 每种作物的养分「净变化」：吃掉多少、又产出多少\n  例：胡萝卜 -4 / +2 / +2 = 吃 4 点催长剂，产出 2 点堆肥和 2 点粪肥\n\n【种植】\n把手里有的种子数量填上，点「一键配平」：\n· 算出「每块地皮的零和配比」—— 养分按地皮（tile）记账，整片地加起来归零不算数，\n  得每块地皮自己归零；凑不满 4 株的那种，提示你靠地皮边界放、跟隔壁那块凑\n· 给出要几块地皮、每块怎么摆、用不用施肥\n· 配平建议不会覆盖你填的数量\n\n按 H 开关面板，按 J 在「信息 / 种植」两页之间切换（两个键都能在模组设置里改）。\n面板可以按住标题栏拖动，位置会记住，下次进游戏还在原地。\n\n纯显示 mod，不修改任何游戏数据。客户端安装即可，联机时其他人不需要装。\nGitHub 源码与文档：github.com/tootony0824/DST-FarmHelper"
author = "tootony0824"
version = "2.6.13"

api_version = 10

dst_compatible = true
dont_starve_compatible = false
reign_of_giants_compatible = false

all_clients_require_mod = false
client_only_mod = true

server_filter_tags = { "farm", "qol", "info" }

configuration_options =
{
    {
        name = "open_key",
        label = "开关面板的按键",
        hover = "在游戏里按这个键打开或关闭面板。默认 H。\n（K 键已从候选里移除：FarmCalc 默认占用 K。J 留给下面的切页键。）",
        options =
        {
            { description = "H", data = 104 },
            { description = "N", data = 110 },
            { description = "B", data = 98 },
            { description = "Y", data = 121 },
            { description = "U", data = 117 },
        },
        default = 104,
    },
    {
        name = "page_key",
        label = "切换页面的按键",
        hover = "按这个键在「信息 / 种植」两页之间循环切换。默认 J。\n面板没打开时按它会直接打开并停在「种植」页。\n（别和上面的开关面板键设成同一个，否则会互相打架。）",
        options =
        {
            { description = "J", data = 106 },
            { description = "L", data = 108 },
            { description = "P", data = 112 },
            { description = "N", data = 110 },
            { description = "O", data = 111 },
        },
        default = 106,
    },
    {
        name = "start_open",
        label = "进入游戏时自动展开",
        hover = "选「否」的话，进游戏时面板是收起的，按快捷键才显示。",
        options =
        {
            { description = "是", data = true },
            { description = "否", data = false },
        },
        default = false,
    },
}
