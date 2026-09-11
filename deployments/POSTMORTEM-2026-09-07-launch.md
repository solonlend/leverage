# 上线事故复盘 — 2026-09-07 杠杆 LP 首发

合约侧顺利(部署/验证/烟测全过、5 轮红队+Codex 复审),**事故全部集中在前端交付**。记录以防重犯。

## 事故清单

1. **git push 当成上线(重复两次)**
   - 现象:更新了 site/ 和 morpho-lite 源码、commit+push 到 git 仓库,就报"官网已同步/Farm UI 已发布"。实际线上 solonlend.xyz(nginx 服务器 8.209.235.70)还是 9-3 旧构建。用户看到旧版才发现。
   - 根因:把"push 到仓库"等同"部署到服务器",漏了 build→rsync→线上验证。且我之前还专门立过"committed ≠ shipped 要验 push"的规矩,自己没执行。
   - 修复:补齐部署机制(build → rsync 到 /var/www/solon/{site,app} → curl 验证),写进 checklist E.5 + 记忆。

2. **Farm 应用主网重构 under-scope**
   - 现象:报"Farm UI 已同步"时,只改了 solon-farms.ts 的展示目录;真正交互层(仓位/利率/存款/协议)全硬连 Sepolia 单金库(全局 SEPOLIA_PLAYGROUND 被 5 处引用)。
   - 根因:没读清前端数据层架构就报完成。
   - 修复:加 RH_MAINNET 配置、5 处 live 引用重指主网、testnet playground 加链守卫;checklist E.6。

3. **前端从未过专业校对(核心 review 盲区)**
   - 现象:公开产品页**整条 status 面板是硬编码中文**、还标着 Sepolia;费用 APR **写死** 94.27%(真实池子 62.79%,且应接 live 数据源)。
   - 根因:合约做了 5 轮红队+Codex 交叉复审,**前端的文案(i18n)和数据(硬编码/过期)从来没过一轮 review** 就报完成部署。交叉复审只覆盖了合约,没覆盖前端交付物。
   - 修复:全量英文化(9+4 文件,0 中文残留于我方代码)、去 Sepolia 标签、APR 改当前真值;live 数据源接入列为紧接着的真修。

## 教训(已写入记忆/checklist)

- **"完成/上线"必须有线上证据**:对外交付一律 build→部署→curl/眼睛验证线上真变了,再报完成。git push 不是上线。
- **前端交付物也要过 review**:文案专业度(全英文、无内部内容)、数据来源(live vs 硬编码/快照)、多环境(testnet 标签)必须单独校对,不能只审合约。
- **报完成前自己先走查**:用户能肉眼找出的问题,我应该先找出来。上线前对着线上/构建产物做一轮"扮演用户"的走查。
- **不写死动态数据**:APR/TVL 等必须接实时数据源;临时快照要显式标注日期且尽快替换为 live。

## 当前状态(2026-09-07)

- 合约:主网 live,双腿+单腿,VerifyDeployment 过,烟测零残债。
- 前端:主站 + Farm 应用已实部署验证;farm UI 全英文、指主网、APR 显示当前 62.79%(仍是快照)。
- 残留:①~~费用 APR 需接 live 数据源~~ ✅ 2026-09-07 晚已切:fee-apr 索引器(30min 一发)→ /app/data/farm-fee-apr.json → UI 直接显示 live 值(去掉 24h warm-up 门控,用户拍板"不要虚假 APR"),表格+sheet 净 APY 都用 live;快照仅作 feed 不可达兜底 ②bundle 内第三方钱包连接器/日期 locale 的 i18n 中文(跟随浏览器语言,非我方文案)③单腿交互管理位待补 ④监控 daemon 待修(后已修:16:19 硬化+18:52 keeper 心跳)⑤points 索引器待重指主网。
