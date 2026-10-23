# 分析扫描元数据复用：迁移与 A/B 对比

日期：2026-10-13。

后续[内存 A/B](analysis-memory-ab-2026-10-13.md)已完成：常规目录峰值基本持平，宽目录峰值增加；本报告的耗时收益不代表内存减少。

## 已完成的改动

`AnalysisInventoryWorker` 新枚举目录时复用刚取得的文件指纹，文件不再立即执行第二次 `lstat`。缓存目录成员时仍逐文件重新读取指纹，继续识别原地内容修改、大小变化和权限变化。未新增全盘常驻索引，临时指纹数组只保留当前新枚举目录。

新增 `metadataReads` 与 `reusedListedFileMetadata` 诊断计数；前者覆盖 worker 内的元数据读取，不包含范围归一化的读取。基线也加入相同计数，使两版计时口径一致。

本次是第一步“同轮元数据复用”，没有改用 `getattrlistbulk`，也没有改动文件名索引或目录大小缓存上限。

## 最终对比

两版使用相同实际文件，先各预热一次，再交替运行 7 次，取中位数。编译使用 `swiftc -O -whole-module-optimization`；仅在基准进程设置 `SWIFT_DETERMINISTIC_HASHING=1`，降低字典随机布局引入的计时波动，产品不设置该环境变量。

“首扫”表示没有上一轮成员快照，**操作系统元数据是热缓存**。本次不包含整盘冷启动、GUI 展现或缓存落盘耗时。

| 范围 / 阶段 | 优化前 | 优化后 | 耗时变化 | 元数据读取次数 |
| --- | ---: | ---: | ---: | --- |
| 磁盘分析首扫：8,000 文件夹具 | 87.07 ms | 68.45 ms | 降低 21.4% | 16,082 → 8,082 |
| 磁盘分析首扫：28,000 文件夹具 | 291.82 ms | 220.00 ms | 降低 24.6% | 56,282 → 28,282 |
| 磁盘分析首扫：当前仓库 8,847 文件 | 165.09 ms | 143.21 ms | 降低 13.3% | 19,189 → 10,342 |
| 图片索引首扫：8,000 文件夹具 | 335.84 ms | 304.25 ms | 降低 9.4% | 16,082 → 8,082 |
| 图片索引首扫：28,000 文件夹具 | 1,157.11 ms | 1,031.15 ms | 降低 10.9% | 56,282 → 28,282 |
| 磁盘分析增量：8,000 文件夹具 | 36.85 ms | 38.59 ms | 增加 4.7% | 8,042 → 8,042 |
| 磁盘分析增量：28,000 文件夹具 | 138.13 ms | 142.74 ms | 增加 3.3% | 28,142 → 28,142 |
| 磁盘分析增量：当前仓库 | 43.42 ms | 43.75 ms | 增加 0.8% | 9,582 → 9,582 |
| 图片索引增量：8,000 文件夹具 | 28.72 ms | 29.36 ms | 增加 2.2% | 8,042 → 8,042 |
| 图片索引增量：28,000 文件夹具 | 107.11 ms | 105.00 ms | 降低 2.0% | 28,142 → 28,142 |

**结论：首扫收益明确；未变化目录的增量扫描没有减少读取，未显示稳定提速。** 本轮增量计时约 -2% 至 +5% 波动，不把这部分算作性能收益，也不能据此证明绝无回退。

元数据调用减少比例：两个夹具约 49.7%；仓库约 46.1%。总耗时不会按同样比例下降，因为目录枚举、过滤、路径处理、指纹字典和报告汇总仍需运行。

## 数据与一致性

- 固定夹具为实际磁盘文件：每个 128 字节，每目录 200 个，扩展名为 `.jpg`。图片索引包含小文件指纹，但这些文件未达到媒体候选大小阈值；不测图片解码或压缩。
- 仓库对比只读扫描 `/Users/didi/OpenSource/Simple-Mole`，没有读文件正文或执行清理。测量时 8,847 个索引文件、磁盘分析汇总 915,902,464 字节。之后保存研究资料会改变仓库文件数，不能假定未来仍是该数。
- 70 对同轮结果全部一致：文件和目录指纹/成员关系 SHA-256、文件数、汇总字节、不完整状态及可复用状态均核对。摘要计算不计入扫描时间。
- 初轮在未固定哈希布局、仓库未预热的情况下，计时波动较大，一组图片增量中位数曾变慢 17.4%。因此完整复跑所有范围，统一预热/哈希设置，并把仓库次数从 3 增为 7；首轮原始数据也保留，未混入最终中位数。
- 环境：arm64，macOS 27.0.1（26A434）。不从这些结果推算百万文件或真实整盘的提速比例。

材料：[最终原始数据](analysis-metadata-ab-2026-10-13/results.jsonl)、[汇总 JSON](analysis-metadata-ab-2026-10-13/summary.json)、[初轮数据](analysis-metadata-ab-2026-10-13/pilot-results.jsonl)、[A/B 驱动](../../script/AnalysisMetadataBenchmark.swift)、[比较脚本](analysis-metadata-ab-2026-10-13/run.py)、[带相同诊断计数的旧版 worker](analysis-metadata-ab-2026-10-13/AnalysisInventoryCache.before.swift)。

工作区基准 HEAD：`dd130c8a1d38e175334efb35b1349dd8bae9d5a0`；实际使用工作区源码快照，未覆盖其它未提交改动。
- 旧版 worker SHA-256：`ded9f47790e731b56390c6e3e1b55f36b7d89f166f2d0fb43e196bef891957c8`。
- 新版 worker SHA-256：`b94634ad9d47deaab10fc2ff41e5a016ef438200b3c0821564990905b9975054`。

## 检查及安装

`script/test_analysis_inventory.sh` 通过，覆盖独立索引、目录范围与硬链接去重、原地修改、增量更新、权限拒绝与恢复、取消、持久化、局部修复，并增加“新列出的文件只读一次、旧成员清单仍重新检查文件”的验证。全项目 Swift 类型检查通过。

按项目约定运行了 `script/install_update.sh`，因原发布签名私钥缺失而中止，已安装 Nori 未替换。A/B 使用新旧命令行二进制，不声称已安装 GUI 已验证。

## 复现

在仓库根目录执行，独立临时目录用于编译和夹具。旧源码快照与当前依赖可能随未来接口变化而需要调整；本记录保留了测量时的版本和校验值。

```bash
source script/test_developer_toolchain.sh
compare_dir="$(mktemp -d /private/tmp/nori-analysis-ab.XXXXXX)"
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
  cp script/AnalysisMetadataBenchmark.swift "$compare_dir/$version/"
  swiftc -O -whole-module-optimization -target "$(uname -m)-apple-macos13.0" \
    -sdk "$SDKROOT" -module-cache-path "$compare_dir/cache-$version" -framework CryptoKit \
    "$compare_dir/$version/"*.swift -o "$compare_dir/$version/benchmark"
done
python3 docs/research/analysis-metadata-ab-2026-10-13/run.py "$compare_dir" "$PWD"
# 检查 results.jsonl / summary.json 后，仅清理本次 mktemp 返回的临时目录。
```

