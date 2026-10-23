# FSearch 对 Nori 文件扫描的优化价值

日期：2026-10-13。范围：FSearch 官方实现、Nori 当前工作区代码、小型命令行基线。未修改产品代码，未启动 GUI 测试，未扫描真实主目录或整盘。

后续落地：同轮元数据复用已实现，见[迁移后的新旧对比](analysis-metadata-ab-2026-10-13.md)。下文“当前实现”与行号指调研时的源码。

## 结论

可以借鉴，但主要收益应放在 **减少扫描时的元数据读取和后续重算**。当前没有证据支持为了毫秒级查询，把 Nori 改成百万文件常驻内存索引器。

截图的 0.4–5 毫秒是另一款 Swift 索引器的查询宣称，缺少可复现方法；它不能代表 FSearch 官方性能，也不能代表建索引、首次扫描或目录大小计算时间。本次按用户补充要求，只评估官方 FSearch 与 Nori。

## 官方方案与 Nori 的区别

FSearch 把读取磁盘与查询分开：扫描目录、读取文件属性，构建数据库，再在已经加载的内存数据里进行匹配。官方源码的首扫仍然使用目录枚举和逐项元数据系统调用；它没有免除全盘首扫。官方大小字段是逻辑大小 `st_size`，不能直接替代 Nori 的分配空间统计。

详细源码位置、固定 commit、查询计时边界及 Linux/macOS 差异见 [FSearch 一手来源笔记](fsearch-primary-sources-2026-10-13.md)。

Nori 已有以下能力：

| 功能 | 已有实现 | 对本次评估的意义 |
| --- | --- | --- |
| 文件名搜索 | `DirectorySearchService.swift:75` 起，持久化 SQLite、FTS5 trigram、字面 LIKE 回退 | 已经是先建索引、再查询；不是每次输入扫磁盘。 |
| 搜索展现 | `DirectoryBrowserModel.swift:390` 起，本地结果先发布，再合并 Spotlight；180 ms 防抖 | 即使查询本身再省 1 ms，也不能据此保证界面立即快 1 ms。 |
| 清理目录计量 | `CleanupScanWorker.swift:79` 起，POSIX FTS，最多 8 个并行 worker | 已经使用底层遍历；不能以“改用 C/POSIX”作为新的提速依据。 |
| 磁盘分析遍历 | `DiskAnalysisWorker.swift:320` 起，FTS、分区任务、全局硬链接去重 | 已有并行及有界结果收集，进一步优化须保留统计口径。 |
| 目录大小缓存 | `DirectorySizeCache.swift:161` 起，成员树、分支失效、校准；`DirectorySizeWatcher.swift:59` 起，局部 FSEvents | 已有增量机制，实际薄弱点是大目录或树释放后无法复用成员信息。 |

文件名索引主动排除应用包内部、`Library/Caches` 等范围（`DirectorySearchService.swift:326` 起），因此它不能直接充当清理扫描的完整文件清单。清理扫描还需要权限、白名单、使用状态和删除前复核。

## 本机基线

环境：arm64，macOS 27.0.1（26A434），`swiftc -O -whole-module-optimization`。只编译并调用现有 `DirectorySearchIndex`、`DirectorySizeCache`、`CleanupScanWorker`；本地化和两个外围值类型使用小型替身，不调用 Spotlight 或 AppState。

临时夹具：8,000 / 28,000 个普通文件，每个写入 128 字节，每目录 200 个文件。刚创建后立即测量，**元数据和磁盘缓存均为热状态**；不包含夹具创建时间，不是冷盘、真实主目录、百万文件或整盘测试。查询先预热一次，再取 11 次的中位数；建索引和大小计算为单次数据。

| 操作 | 8,000 文件 | 28,000 文件 |
| --- | ---: | ---: |
| 文件名索引构建 | 2.764 s | 9.007 s |
| 稀疏关键词 `needle` 查询，返回 8 / 28 项 | 0.101 ms | 0.216 ms |
| 常见关键词 `sample` 查询，返回上限 300 项 | 4.657 ms | 8.249 ms |
| 两字符无匹配 `zz` 查询 | 0.306 ms | 1.043 ms |
| 目录大小首次计算 | 40.95 ms | 136.44 ms |
| 未变化目录再次计算 | 0.031 ms；检查 0 项 | 135.23 ms；检查 28,141 项 |
| 主动释放成员树后计算 | 38.37 ms | 134.94 ms |
| 清理 FTS 仅计算汇总 | 11.93 ms | 46.70 ms |

目录大小与 FTS 的分配空间统计一致：32,768,000 / 114,688,000 字节，所有计量结果完整。两者职责不同：成员树缓存需要构建复用结构，FTS 只返回汇总；这不是“替换成 FTS 就必然快约三倍”的证据。

28,000 文件重复计量再次检查 28,141 个节点、枚举 141 个目录，与源码的单根 25,000 节点上限一致。8,000 文件的第二次计算则无需遍历。**大目录反复重算是已经由代码和夹具共同确认的优化机会。**

复现材料：[Benchmark.swift](fsearch-baseline-2026-10-13/Benchmark.swift)、[原始 JSONL](fsearch-baseline-2026-10-13/results.jsonl)。临时夹具已在评估后清理；基准程序需独立临时目录，重复运行前须更换目录，不能放进正在扫描的范围。

```bash
source script/test_developer_toolchain.sh
study_dir="$(mktemp -d /private/tmp/nori-fsearch-baseline.XXXXXX)"
cp docs/research/fsearch-baseline-2026-10-13/Benchmark.swift "$study_dir/"
cp SimpleMole/Services/{DirectorySearchService,DirectorySizeCache,CleanupScanWorker}.swift "$study_dir/"
swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" \
  -sdk "$SDKROOT" -module-cache-path "$study_dir/cache" -lsqlite3 \
  "$study_dir/"*.swift -o "$study_dir/benchmark"
"$study_dir/benchmark" "$study_dir/fixtures"
# 完成后仅清理本次 mktemp 返回的临时目录。
```

## 建议按这个顺序推进

### 1. 先减少同一轮扫描的重复元数据读取

`AnalysisInventoryCache.swift:388` 对新列出的 child 读取一次指纹；加入 files 后，又在 `:418` 读取一次。首次扫描或目录成员变化时，同一个普通文件会在同一轮连续读取两次。

优先试验复用本轮已读指纹，减少重复 `lstat` 和路径转换。保留“旧缓存校准时重新读取文件”的规则：文件正文修改不会总是改变父目录 mtime。现有 Agent `ScanSession` 已经复用同轮目录计量（`AgentInventory.swift:94` 起），可延续这个方向，无需先引入全局常驻索引。

这处重复调用已确认；整体耗时收益尚未测量。不能把“少读一次”直接换算成“整个扫描快一倍”。

### 2. 试验 macOS 批量元数据读取

用 `getattrlistbulk` 做一段小范围枚举对比，和当前 `contentsOfDirectory + lstat`、FTS 比较。目标是一次获取多项名称、类型、文件 ID、时间、flags 和分配大小，减少逐文件 syscall / Foundation 包装。

Apple SDK `sys/attr.h` 明确提供 `ATTR_CMN_RETURNED_ATTRS`、`ATTR_CMN_ERROR`、`ATTR_FILE_ALLOCSIZE`、`ATTR_DIR_ALLOCSIZE` 等字段；详细一手依据见来源笔记。实现时逐项检查返回 mask/error；文件系统或字段不支持时回退现有实现，不假定本机 SDK 字段在所有部署系统/卷上都有效。

Apple 的 `ALLOCSIZE` 包含所有 fork 的分配大小，不能直接保证与现有 `st_blocks × 512` 完全一致。必须先对齐目录自身、硬链接、符号链接、资源 fork 等统计结果，再评估速度。

先在目录大小/分析首次枚举上验证，收益明确后再推广。这是可验证的候选方案，**本次未实现或测量 bulk 后端**。

### 3. 再处理大目录缓存的复用

`DirectorySizeCache.swift:257` 的总预算为 50,000 节点、单根 25,000；`:479` 起会丢弃超限的成员树。落盘只保留根汇总（`:140` 起），树释放或重启后需要重新测量。

如果真实目录的重复重算占用明显，可评估把必要的目录成员/指纹分页保存在 SQLite，内存只保留活跃部分；用 FSEvents 标记受影响分支，事件丢失或离线变化时重新校准。不要单纯放宽内存节点上限换取速度，应同时衡量峰值和空闲内存、数据库大小、更新耗时。

这一项比去掉重复读取复杂，建议在第一轮计时结果证明有收益后单独做方案。

## 后续验证的判定标准

- 分开测建索引、首次计量、未变化复用、单文件更新、大目录树释放后重算、索引查询及 UI 延迟。
- 在相同范围和统计语义下比较耗时、元数据调用次数和内存；冷热状态分别标明。
- 保留硬链接去重、符号链接边界、跨卷限制、云端未下载目录、权限拒绝、取消及下限标记。
- 搜索快照/大小缓存只用于展示和发现；删除前继续使用现有实时身份、权限与占用复核。
- 本次结论是可行性及基线评估；未承诺整体提速比例，未改变已安装 Nori 的行为。

