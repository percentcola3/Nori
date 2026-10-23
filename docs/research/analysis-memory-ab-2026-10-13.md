# 元数据复用后的扫描内存对比

日期：2026-10-13。对比对象与上一轮[耗时 A/B](analysis-metadata-ab-2026-10-13.md)相同：同轮元数据复用前后的 `AnalysisInventoryWorker`。本次没有修改产品代码。

## 结论

**没有测到内存减少。常规目录的扫描峰值基本持平；单目录包含大量文件时，峰值增加。扫描后保留结果的实际堆占用基本相同。**

旧版 worker SHA-256：`ded9f47790e731b56390c6e3e1b55f36b7d89f166f2d0fb43e196bef891957c8`。
新版 worker SHA-256：`b94634ad9d47deaab10fc2ff41e5a016ef438200b3c0821564990905b9975054`。
两份源码与耗时对比一致；旧版也包含相同的读取次数诊断计数。

## 扫描峰值

单位 MiB（1 MiB = 1,048,576 字节），均为 7 个独立进程的中位数。峰值采用 Darwin `TASK_VM_INFO.ledger_phys_footprint_peak`，不是虚拟地址空间大小。

| 范围 / 扫描类型 | 旧版峰值 | 新版峰值 | 变化 |
| --- | ---: | ---: | ---: |
| 8,000 文件，分散目录，磁盘分析 | 10.766 | 10.938 | +0.172（+1.6%） |
| 28,000 文件，分散目录，磁盘分析 | 30.266 | 30.454 | +0.188（+0.6%） |
| 28,000 文件，同一目录，磁盘分析 | 31.922 | 36.469 | **+4.547（+14.2%）** |
| 28,000 文件，分散目录，图片索引 | 35.126 | 35.282 | +0.156（+0.4%） |
| 28,000 文件，同一目录，图片索引 | 34.813 | 38.344 | **+3.531（+10.1%）** |
| 当前仓库 8,890 文件，磁盘分析 | 13.329 | 13.407 | +0.078（+0.6%） |

宽目录磁盘分析的 7 次范围：旧版 31.907–31.938 MiB，新版 32.891–36.485 MiB；增幅中位数不是每次运行都精确相同。宽目录图片索引范围：旧版 34.813–35.016 MiB，新版 38.344–38.360 MiB。

“分散目录”每目录 200 个文件；“同一目录”把 28,000 个文件放入单个目录。夹具是磁盘上的 128 字节普通文件，不读取图片正文。仓库仅只读扫描，测量后新增报告会改变其文件数。

## 保留结果与释放结果

这一部分使用 `malloc_zone_statistics(nil, ...).size_in_use`，表示所有 malloc 区中正在使用的堆字节。它不包含全部框架/内核账本成本，也不能替代物理 footprint。

| 范围 / 类型 | 保留结果：旧版 | 保留结果：新版 | 释放结果后：旧版 / 新版 |
| --- | ---: | ---: | ---: |
| 8,000 分散文件，磁盘分析 | 4.660 | 4.660 | 0.181 / 0.181 |
| 28,000 分散文件，磁盘分析 | 17.616 | 17.616 | 0.181 / 0.181 |
| 28,000 同目录文件，磁盘分析 | 17.367 | 17.367 | 0.182 / 0.182 |
| 28,000 分散文件，图片索引 | 9.845 | 9.845 | 0.183 / 0.183 |
| 28,000 同目录文件，图片索引 | 9.867 | 9.867 | 0.183 / 0.183 |
| 当前仓库，磁盘分析 | 5.801 | 5.801 | 0.188 / 0.188 |

堆占用没有因为元数据复用而缩小。新版新增的临时指纹数组不留在扫描结果中，但会影响扫描过程的分配与峰值。

结果释放后，物理 footprint 未必立刻下降：例如 28,000 分散文件磁盘分析，实际在用堆已经降到约 0.181 MiB，但 footprint 仍约为旧版 30.266 / 新版 30.454 MiB。分配器保留的可复用页和进程其它内存仍然存在；不能把“对象已释放”描述成“操作系统内存马上全部归还”。

## 为什么宽目录增加更多

本机 `MemoryLayout<AnalysisFileFingerprint>.stride` 为 72 字节，可选指纹为 80 字节。当前优化用 `freshFingerprints` / `listedFingerprints` 数组保存整个新枚举目录的文件指纹，随后写入结果快照。

- 每目录 200 项时，新增指纹有效载荷约 16,000 字节。
- 单目录 28,000 项时，有效载荷至少 2,240,000 字节，另有数组容量增长及分配器成本。
- 物理峰值和保留结果的堆占用表现，符合“临时数组及分配产生额外成本，最终结果结构未缩小”的预期。未用分配跟踪把每一字节峰值逐项归因，不能认定全部 4.547 MiB 都等于数组净载荷。

下一步应优先评估在枚举中直接消费已读取的指纹、或采用有界批次，避免整目录暂存，保留减少重复读取的收益。真正降低长期内存仍要缩小被保留的成员/路径/结果；这次元数据复用没有完成这一点。本次仅做对比，没有继续修改扫描实现。

## 测量方法与范围

- arm64，macOS 27.0.1（26A434），`swiftc -O -whole-module-optimization`。
- 同一组真实文件，各版先运行一次预热，再交替运行 7 次；基准进程使用 `SWIFT_DETERMINISTIC_HASHING=1`。每次扫描都启动全新进程，峰值不会混入前一次扫描。
- 内存专用驱动不执行 SHA-256 / 逐文件 JSON 编码。结果 JSON 在全部内存读数之后输出，夹具生成也在独立进程进行。
- 记录启动基线、扫描结束、autoreleasepool 退出后保留结果 200 ms，以及解除结果引用 200 ms 后的内存；同时保存 RSS 高水位、当前 footprint、峰值 footprint、堆在用/保留字节。
- 84 次正式扫描、42 对新旧基本输出检查通过：文件/目录数、总字节、错误数与可复用状态相同。完整指纹一致性及功能回归仍引用前一次 A/B 与回归测试，本次没有在内存阶段重复做高内存校验。
- 测量对象是命令行扫描模块。没有启动 GUI，也没有将该模块的几十 MiB 读数宣称为整个 Nori 的内存占用；`AnalysisInventoryCache` 的其它缓存、界面与其它功能不在本次测量中。

材料：[原始读数](analysis-memory-ab-2026-10-13/results.jsonl)、[中位数和范围](analysis-memory-ab-2026-10-13/summary.json)、[内存驱动](../../script/AnalysisMemoryBenchmark.swift)、[比较脚本](analysis-memory-ab-2026-10-13/run_memory.py)。

## 复现

编译依赖清单与耗时 A/B 相同，把驱动换成 `AnalysisMemoryBenchmark.swift`：

```bash
source script/test_developer_toolchain.sh
compare_dir="$(mktemp -d /private/tmp/nori-analysis-memory-ab.XXXXXX)"
mkdir "$compare_dir/before" "$compare_dir/after"
while IFS= read -r relative; do
  case "$relative" in
    script/AnalysisInventoryCacheTests.swift|SimpleMole/Services/AnalysisInventoryCache.swift) continue ;;
  esac
  cp "$relative" "$compare_dir/before/"
  cp "$relative" "$compare_dir/after/"
done < <(rg -o '"\$ROOT_DIR/(SimpleMole/[^" ]+|script/[^" ]+)"' script/test_analysis_inventory.sh \
  | sed 's/"\$ROOT_DIR\///; s/"$//')
cp docs/research/analysis-metadata-ab-2026-10-13/AnalysisInventoryCache.before.swift \
  "$compare_dir/before/AnalysisInventoryCache.swift"
cp SimpleMole/Services/AnalysisInventoryCache.swift "$compare_dir/after/"
for version in before after; do
  cp script/AnalysisMemoryBenchmark.swift "$compare_dir/$version/"
  swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" \
    -sdk "$SDKROOT" -module-cache-path "$compare_dir/cache-$version" \
    "$compare_dir/$version/"*.swift -o "$compare_dir/$version/benchmark"
done
python3 docs/research/analysis-memory-ab-2026-10-13/run_memory.py "$compare_dir" "$PWD"
# 检查 results.jsonl / summary.json 后，仅清理本次 mktemp 返回的临时目录。
```

