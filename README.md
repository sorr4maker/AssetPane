# 资产窗 AssetPane

贴在 Mac 桌面上的基金持仓面板 + 菜单栏图标。纯自用，原生 SwiftUI。

它不自己存持仓：持仓、交易记录、定投计划都放在开源工具 [real-time-fund（基估宝）](https://github.com/hzm0321/real-time-fund) 里，资产窗**只读**这些数据，再自己拉历史净值和估值，在桌面上用简洁的方式显示。

## 显示什么

- 顶部：总资产、当日涨跌（有估值时标「估」）、持有收益。
- 按地区分卡片（亚太 / 欧洲 / 美洲，黄金单独一张），卡片里每行是一个指数；同一指数的基金合并（比如全部纳斯达克 100 合成一行）。分类按基金名称里的关键词判断，认不出的归「其他」。
- 底部「定投」概览：每个交易日按地区、指数汇总的定投金额，不写基金名。
- 鼠标移到指数行 / 地区行上会亮起小框，点一下弹出「详细持仓」窗口：每只基金的市值、份额、成本价、现价、持有收益、定投金额。
- 面板不滚动，所有内容始终可见；拖大拖小时字号和间距按比例变化（不是拉伸画面，所以文字清晰）。右键面板或点底部「调整大小」进入调整模式，可以拖动、缩放。
- 红涨绿跌。

## 工作方式

1. App 里常驻一个不可见的 WKWebView，载入打包进来的基估宝页面（通过自定义协议 `assetpane://` 提供，不开本地端口）。基估宝负责按定投计划自动生成买入。
2. 资产窗通过 `evaluateJavaScript` 读它存在 localStorage 里的 `funds` / `holdings` / `transactions` / `dcaPlans`。
3. 历史净值取东方财富 `pingzhongdata`（缓存到 `~/Library/Application Support/AssetPane/nav`），当日估值取天天基金 `fundgz`；QDII 等没有估值的基金用最近一个已确认净值。
4. 菜单栏「管理持仓与定投…」打开基估宝页面，用来添加基金、填持仓和定投。

数据都在本机：没有账号、没有云同步、不上报任何数据。基估宝自带的 Sentry / Google Analytics 只有在配置了密钥时才启用，这里没配。

## 构建

需要 macOS 14+、Swift 6 工具链（Xcode）、Node ≥ 20.9。

```bash
# 1) 准备基估宝（要打上本仓库 patches/ 里的改动）
git clone https://github.com/hzm0321/real-time-fund.git ~/Developer/real-time-fund
cd ~/Developer/real-time-fund
git checkout 85e1237
git apply /path/to/AssetPane/patches/real-time-fund.patch
npm install --ignore-scripts
npm run build            # 生成 out/

# 2) 打包 App
cd /path/to/AssetPane
Scripts/build-app.sh --install     # 生成 build/AssetPane.app 并安装到 ~/Applications
# 网页目录默认是 ~/Developer/real-time-fund/out，可用 WEB_SRC=… 指定
```

### patches/real-time-fund.patch 里改了什么

- 新增 `app/lib/assetCurve.js`、`app/components/AssetCurveCard.jsx`，在基估宝「汇总」标签里加一张资产曲线（资产窗本身已不用曲线）。
- **修复上游的一个问题**：`app/page.jsx` 启动时的 `init` 用了渲染时的旧闭包值 `dcaPlans`（空对象）去比较，发现「不一样」就把刚从 localStorage 读进来的定投计划覆盖成空，导致**重启后定投计划全部丢失**。补丁改成用 `useStorageStore.getState().dcaPlans`。资产窗依赖这一点（定投计划要在重启后保留）。

## 导入持仓 / 定投

菜单栏「导入持仓文件…」读取 `~/Library/Application Support/AssetPane/import.json`，写进基估宝的 localStorage（写之前把原来的 funds / holdings / dcaPlans 备份到同目录的 `import-backup-*.json`，同代码的持仓覆盖，然后重载页面）。

```jsonc
{
  "holdings": [                       // 也可以整个文件就是这个数组
    {"code": "000001", "name": "示例基金", "share": 100.00, "cost": 1.2345},      // 份额 + 成本价（优先）
    {"code": "000002", "name": "示例基金2", "amount": 500, "profit": 12.5, "date": "2026-01-01"}  // 或：金额 + 持有收益，按净值反推
  ],
  "funds": [{"code": "000003", "name": "只加进列表、暂无持仓"}],
  "plans": [
    {"code": "000001", "amount": 10, "cycle": "daily", "firstDate": "2026-01-02"},   // daily | weekly | biweekly | monthly
    {"code": "000002", "remove": true}                                               // 删除这只基金的定投计划
  ]
}
```

注意：基估宝对同一只基金只存一条定投计划；持仓导入会覆盖同代码的份额和成本，所以定投开始执行后不要再整体重导持仓。

## 调试用环境变量

没有屏幕录制权限时，靠这些在不看桌面的情况下检查：

| 变量 | 作用 |
|---|---|
| `ASSETPANE_DEBUG_DIR=目录` | 15 秒后把面板画成 `snapshot.png`，并写 `summary.txt` |
| `ASSETPANE_DEBUG_DETAIL=纳斯达克100` 或 `地区:欧洲` | 自动打开详情窗口，截图为 `detail.png` |
| `ASSETPANE_DEBUG_EDIT=1` | 进入「调整大小」模式 |
| `ASSETPANE_DEBUG_HOVER=1` | 所有可点击行显示悬停小框 |
| `ASSETPANE_DEBUG_KEYS=a,b` | 把这些 localStorage 键的值写进 `keys.txt` |
| `ASSETPANE_DEBUG_IMPORT=1` | 启动后自动执行一次导入（不弹窗，结果写日志） |
| `ASSETPANE_DEBUG_SEED=1` / `ASSETPANE_DEBUG_CLEAR=1` | 写入 / 清除两只测试基金 |

`Scripts/resolve-funds.py 基金名…` 按名称查候选基金代码（东方财富搜索接口）。

## 许可与声明

- 本仓库自己写的代码（`Sources/`、`Scripts/`、`Resources/`）没有附带许可证文件，按默认的「保留所有权利」处理；要复用请先联系作者。
- `patches/real-time-fund.patch` 是对 AGPL-3.0 项目 real-time-fund 的修改；打包进 App 的网页也来自该项目，分发时需遵守其 AGPL-3.0 条款。
- 数据来自东方财富、天天基金等公开接口，可能有延迟和误差；估值与真实结算数据会有差异。仅供个人记录参考，不构成任何投资建议。
