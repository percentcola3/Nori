# 目录搜索：Everything 调研与 macOS 实现

调研日期：2026-10-04。

目录 tab 的定位是 Finder 的增强入口：直接浏览、路径复制、隐藏文件显示、磁盘占用和常用文件操作；复杂文件管理继续交给 Finder。搜索以文件名为主，不读取正文。

硬盘占用使用独立的后台计算与缓存，切换页面后继续补齐结果，并每 6 小时校准。数值的时效与下限标记见[目录硬盘占用说明](directory-sizes.md)。

导航集中在路径面包屑中：点击上级目录直接返回，宽度不足时中间层级收进省略号菜单，长目录名自动缩略。省略的层级仍可访问，复制路径始终复制完整地址。路径菜单提供前往指定地址；原有前进、后退和上一级快捷键继续可用。

每个文件和文件夹右侧的省略号菜单以及右键菜单提供复制、剪切、粘贴、重命名、移入废纸篓和 Finder 打开。对文件夹执行粘贴会直接写入该文件夹，对文件执行粘贴会写入其所在目录，两者均保持当前浏览位置。已选中项目的复制、剪切、删除和 Finder 打开支持多选；当前路径粘贴也可从列表空白处的右键菜单访问。

## Everything 可以复用什么

voidtools 的 [官方 FAQ](https://www.voidtools.com/faq/) 将 Everything 定义为 Windows 文件名搜索引擎：先建立文件/文件夹名称索引，在索引里过滤结果；NTFS 索引通过系统 USN Journal 更新，应用退出期间的改动也能补上。其速度依赖 NTFS 的文件系统元数据和变更日志，不能直接移植到 macOS 的 APFS。

[官方 License.txt](https://www.voidtools.com/License.txt) 对 Everything 列出了 MIT 风格的许可。宽松许可和公开完整索引引擎源码是两件事：[下载页](https://www.voidtools.com/downloads/) 提供 SDK、ES 命令行客户端、ETP server 的源码/接口，但没有提供可直接嵌入 macOS 的完整 Everything 索引引擎。不能把这些组件误认成跨平台 Everything 核心。

[Everything SDK](https://www.voidtools.com/support/everything/sdk/) 通过 Windows IPC 查询已经运行的 Everything，既不能在 macOS 工作，也不替代索引器。本功能没有引入 Everything 的代码或二进制；借鉴“文件名索引 + 快速查询”的方法。

## Nori 当前实现

搜索统一为全局入口，无需切换范围。有关键词时立即显示当前目录匹配，随后合并本地索引与 Spotlight 结果；当前目录直属项目排在最前，其次是子目录，再是其他位置。每组内完整文件名匹配优先，其余按名称与路径稳定排序，合并去重后最多显示 300 项。清空输入恢复目录浏览。粘贴路径继续按路径精确度排序。索引管理收在搜索框旁的菜单中。

1. **全局系统索引**：`NSMetadataQuery` 搜索 `NSMetadataQueryLocalComputerScope`，复用 macOS Spotlight 已维护的索引。查询按文件名进行，不在每次输入时扫描硬盘。查询可取消，结果上限为 300（服务最多允许 1,000），收集完成、达到上限或 5 秒后停止。
2. **本地补充索引**：用户显式构建所选目录的文件名索引，UI 初始建议主目录。SQLite 存在 `~/Library/Application Support/Nori/DirectoryIndex/files.sqlite`，应用重启后复用。该索引包含 Spotlight 常忽略的 `.开头` 文件和目录，可以再加入其他目录。支持 SQLite FTS5 trigram 的系统直接进行子串索引查询；旧版 SQLite 使用相同语义的字面 `LIKE` 查询回退。1–2 字符查询也使用回退。
3. **字面搜索**：名称与查询都进行 Unicode 大小写/重音折叠；`%`、`_`、引号和反斜杠作为普通字符处理。关闭隐藏文件时，所有 `.开头` 祖先目录下的结果均过滤，不仅检查最后一级文件名。查询只返回仍存在的路径。
4. **低成本构建**：只枚举名称和必要元数据，不打开内容，不解析符号链接，不深入应用包；使用 `lstat` 检查 File Provider 的 `SF_DATALESS` 目录以及 iCloud 下载状态，跳过未下载云目录的子项；跳过回收站、Spotlight/FSEvents 内部目录和 `Library/Caches`。权限拒绝路径跳过并计入进度。遍历在后台 actor 执行，每 256 项让出执行器，进度可读取，构建可取消。替换快照原子发布；失败或取消不会丢失之前的索引。失效的符号链接仍然保留，便于显示、重命名或移入废纸篓。
5. **变化与时效**：Nori 内部创建、重命名、复制、移动、废纸篓等操作后，`refresh(paths:)` 只更新涉及的文件/子树。Spotlight 的外部改动由系统维护；本地补充索引是有时间戳的快照，外部新增/重命名的隐藏文件需要通过“更新索引”重新构建。它当前没有驻留 FSEvents 全盘监听，也不会在后台频繁重扫主目录。UI 应明确显示索引时间与手动更新入口。

Spotlight 隐私设置、索引关闭、目录权限、云端未下载项目会影响系统结果；本地索引只能涵盖已构建且当前进程有权访问的范围，因此不声称 Everything 那样完整覆盖整个磁盘。显示结果合并时以路径去重，将本地结果和系统结果统一提供“打开位置/用 Finder 打开”。文件内容编辑和更复杂的管理功能沿用系统默认应用/Finder。

## 验证

`script/test_directory_search.sh` 使用临时目录和临时 SQLite，覆盖隐藏祖先、Unicode、字面通配符/引号/反斜杠、符号链接/应用包、结果上限、跨服务持久化、增量新建/重命名/删除、范围边界、构建中取消、快照原子性与查询取消。它不重建用户 Spotlight 索引，也不索引真实主目录。

## Paths and system reveal

The search field accepts absolute paths, `~/` paths, relative paths containing `/`,
quoted paths, shell-escaped spaces and local `file://` URLs. Plain filenames retain
one unified global search, with current-folder matches shown first. Path results are ordered by full-path
similarity, with exact paths first. Bounded traversal of existing ancestors,
the local index and Spotlight supply candidates; adjacent-letter typos, partial
components and differences in letter case are supported. Double-click a match to
open a directory or select a file in its containing directory.

Finder and other macOS apps can use **Services → Reveal in Nori** with selected
files or path text. The app also accepts `nori://reveal?path=<percent-encoded-path>`.
For example `nori://reveal?path=%2FUsers%2FShared`. A file is selected in its parent
folder, without launching its associated application. The service is registered
when Nori starts; macOS controls its visibility in the Services menu.
