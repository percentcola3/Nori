# FSearch 对 Nori 文件扫描的参考价值

研究日期：2026-10-13。范围：FSearch 官方源码与 Apple 一手文档；未运行 FSearch，也未验证截图作者的 Swift 索引器。

## 结论

可以借鉴的是**扫描后保存元数据、复用目录汇总、按变更局部更新**。FSearch 的毫秒级查询来自已经建好的内存索引，不能据此推断首次扫描或全盘大小计算也只需毫秒。截图的“120 万文件、0.4–5 ms”没有在本次官方来源中得到验证，不能作为 Nori 的性能承诺。

FSearch 的扫描器仍逐目录遍历、逐项读取元数据。直接移植不会自动加快 Nori 现有 POSIX 扫描；macOS 上更值得单独测量的是 `getattrlistbulk` 批量取元数据，以及避免不同功能重复读取同一轮扫描结果。[F1][F2][A1]

## 已核实的 FSearch 实现

所有 FSearch 代码链接固定在 **`cb6cd67f9ef12fedcf6a160b6a38faf492f7c989`**。其 Meson 版本为 **0.3 开发树**，不代表已发布稳定版都具备下列实现。[F0]

| 环节 | 官方实现 | 对 Nori 的意义 |
| --- | --- | --- |
| 初次扫描 | `opendir/readdir`，根目录 `lstat`，每项 `fstatat(AT_SYMLINK_NOFOLLOW)`；可限制同一文件系统。[F1] | 仍需读取全部目录项及元数据，不是绕过文件系统的特殊扫描机制。 |
| 数据字段 | 默认名称、父目录关系、大小、修改时间；文件大小来自 `st_size`。[F1][F3] | 一次读取后能支撑搜索、大小排序、变更比较。其逻辑大小不能替代清理功能的磁盘占用。 |
| 目录大小 | 文件插入/移除、大小变化时，把大小差额递归传播到祖先目录；保存文件时也写目录汇总。[F4][F5] | 值得借鉴局部维护汇总；但扫描仍需读叶子文件，且该路径未记录 `dev/ino`、未对硬链接去重。 |
| 内存条目 | 一个分配块存父指针、标志、可选属性和文件名；完整路径由父目录链按需拼接。[F4] | 避免每个文件重复保存完整父路径。仍是把索引常驻内存，不能假定没有内存成本。 |
| 查询 | 在当前排序的内存条目数组逐项匹配；至少 1,000 项时通常按处理器线程数分段并行。普通子串用 `strstr/strcasestr`，另有 Unicode/正则等匹配器。[F2][F6] | 不是倒排检索带来的普遍复杂度下降；不能据此认定比 Nori 的 SQLite FTS5 更快。 |
| 排序 | 多个预排序数组共享条目指针；分块数组目标 2,048 项，以减轻插入删除成本。[F2][F7] | 用额外数组内存换切换排序速度；每个额外指针数组在 64 位环境至少约 `8 × 条目数` 字节，尚未算容器容量。 |
| 持久化 | 自定义二进制文件，名称按相邻名称共有前缀压缩，父目录存编号；大小/mtime 和排序编号数组一起写入；加载时重建内存条目。[F5] | 持久索引能避免每次启动从零开始。它不是 SQLite，也不是只靠 mmap 查询的磁盘索引。 |
| 更新 | 开发树已有 Linux fanotify/inotify；按创建、删除、移动、属性变化更新内存索引，另有定时/手动重扫管理；监控与工作线程分开。[F8][F9] | 可以借鉴变更批处理、局部更新和重扫兜底；macOS 应使用现有 FSEvents 路径。 |

`fsearch_database_index_store_search` 的 `search_time` 在结果匹配/收集后记录，随后才处理结果视图；它不包含首次建索引，也不是完整输入到绘制延迟。[F2] 文件类型未被索引，官方 README 明确说明按 Type 排序可能慢。[F0]

## macOS 可借鉴的直接优化点

### 1. 批量读取目录项和属性

Apple 的 `getattrlistbulk` 每次返回多个目录项及所请求的属性，符号链接返回链接本身的信息。必须请求 `ATTR_CMN_NAME` 与 `ATTR_CMN_RETURNED_ATTRS`，检查每条实际返回属性及 `ATTR_CMN_ERROR`，循环到返回 0；顺序没有保证，同一个 fd 不可混用 `readdir` 与 bulk。[A1]

它能减少逐项系统调用，但官方文档没有给出适用于 Nori 的加速倍数。应先在同一夹具上与现有 `fts/lstat` 比较，再决定是否替换；对属性缺失/不支持的文件系统需要回退。[A1]

大小口径必须单独验证：Apple 定义 `ATTR_FILE_TOTALSIZE` 为各 fork 的逻辑总大小，`ATTR_FILE_ALLOCSIZE` 为各 fork 的磁盘占用；`ATTR_CMN_FILEID` 相当于 `st_ino`。不能直接认定 `ALLOCSIZE` 与当前 `st_blocks × 512` 在所有对象上完全相同。[A2] Nori 的应用还需对齐设备标识、硬链接数量/去重、目录自身分配大小、符号链接和挂载边界；这些属于实现验证要求，不是 FSearch 已解决的 macOS 合同。

### 2. 元数据快照与增量更新

Apple 官方建议把目录树元数据快照与 FSEvents 配合使用，存最后已处理事件 ID，可以补看应用未运行期间的变更。建立快照时要**先开始监控再扫描**，重新扫描扫描期间发生变化的目录，避免漏变更。[A3]

FSEvents 是变更提示，不是绝对完整的状态数据库：`MustScanSubDirs` 表示必须递归重扫；`UserDropped/KernelDropped` 表示丢事件，需要完整重扫所监控目录。Apple 还建议定期完整校验；持久化事件还需关联卷 UUID，不能只用可能重启变化的设备编号。[A3]

因此，复用缓存的收益主要在后续查询和第二次计算。用于清理时，旧索引只能帮助发现候选，真正删除前仍应核对实时文件身份与状态。

## 移植成本

FSearch 是 C + GTK3/GLib，依赖 PCRE2、ICU 等；当前监控依赖 Linux fanotify/inotify，README 的官方分发主要面向 Linux（FreeBSD 由第三方维护）。项目不是可直接嵌入 SwiftUI 的 macOS 索引器。[F0][F10]

建议借鉴数据布局与增量维护方式，保留 Nori 原生 Swift/POSIX 与 FSEvents；只有本地测量显示查询或内存存在明确瓶颈，才考虑整套常驻内存索引。

## 一手来源

- **F0**：[README](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/README.md)；[meson.build](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/meson.build#L1-L10)。
- **F1**：[扫描字段与算法](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_scan.c#L68-L208)。
- **F2**：[线程池与查询](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_index_store.c#L1352-L1488)；[逐项匹配](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_index_store.c#L227-L255)。
- **F3**：[默认索引属性](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_index_properties.h#L37-L41)。
- **F4**：[条目布局/路径拼接](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_entry.c#L23-L56)；[祖先大小差额更新](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_entry.c#L560-L616)；[父关系变更累加/扣除](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_entry.c#L723-L755)；[按需分配属性](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_entry.c#L825-L887)。
- **F5**：[持久化编码](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_file.c#L654-L805)；[保存](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_file.c#L925-L1125)；[加载](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_file.c#L1225-L1425)。
- **F6**：[字符串匹配器](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_query_matchers.c#L185-L234)。
- **F7**：[分块排序数组](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_chunked_array.c#L13-L40)。
- **F8**：[变更处理](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_index.c#L640-L795)；[监控初始化](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_index.c#L936-L951)。
- **F9**：[重扫管理](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_rescan_manager.c)；[监控/工作线程](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/src/fsearch_database_index_store.c#L757-L773)。
- **F10**：[监控平台检测](https://github.com/cboxdoerfer/fsearch/blob/cb6cd67f9ef12fedcf6a160b6a38faf492f7c989/meson.build#L36-L80)。
- **A1**：[Apple XNU getattrlistbulk man page](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/getattrlistbulk.2#L32-L204)。
- **A2**：[Apple XNU getattrlist 大小定义](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/getattrlist.2#L1054-L1080)；[FILEID 定义](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/bsd/man/man2/getattrlist.2#L704-L712)。
- **A3**：[Apple File System Events Programming Guide — Using the API](https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/FSEvents_ProgGuide/UsingtheFSEventsFramework/UsingtheFSEventsFramework.html)，重点为 Handling Events、Working with Persistent Events、Building a Directory Hierarchy Snapshot、Special Considerations for Per-Device Streams。
