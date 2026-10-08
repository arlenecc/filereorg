# FileReorg — 文件重组织工具

一个 macOS 原生（SwiftUI）桌面工具：扫描指定目录下的全部文件，做**全局 SHA-256 排重**，再按**文件创建年份**建立 4 位数字目录归档，同时保留原有目录结构，并自动清理移动后变空的原始目录。

- 平台：macOS 13.0+
- 语言/工具链：Swift 5.9（Swift Package Manager）
- 当前版本：1.1.0
- 界面语言：简体中文

---

## 一、核心功能

### 1. 目录扫描
- 递归遍历目标目录，收集文件大小、创建日期、修改日期等元数据。
- **跳过符号链接**（既不作为文件计入，也不深入遍历），避免重复统计与循环引用。
- 结果**按相对路径排序**，保证排重的保留策略可预测、可复现。
- 识别并记录所有子目录与其中的**空目录**。
- 单项读取失败时**计数并继续**，不中断整体扫描。
- 支持协作式取消。

### 2. 全局排重
- 两阶段策略：**先按文件大小分桶**（大小唯一 → 必然唯一，无需哈希），仅对大小冲突的文件计算 SHA-256。
- 哈希采用**流式读取**（1 MB 固定缓冲区），大文件不会占用额外内存。
- 有界并发计算，并发度默认 `activeProcessorCount × 2`。
- 重复组内**按相对路径排序，保留第一个**，其余标记为待删除。
- 统计重复文件数量与**可释放空间**。
- 读取失败的文件视为唯一（标记 `unhashable:`），不中断流程。

### 3. 归档计划（只读推演，不改动磁盘）
- 目标路径规则：`根目录 / 创建年份(4位数字) / 原相对路径`，**完整保留原有目录层级**。
- 年份来源优先级：创建日期 → 修改日期 → `未知年份`；年份补零至 4 位（如 `0999`）。
- **幂等设计**：已位于对应年份目录内的文件标记 `inPlace`，不重复移动，不会产生 `2023/2023/` 嵌套。
- 预估处理后的最终目录集合与数量：
  `最终目录 = (目标目录 ∪ 原有目录) − 移动后变空的原始目录`
- 预先计算需要清理的空目录列表，并按**路径深度由深到浅**排序。

### 4. 执行处理
1. **可写性预检**：目标目录不可写时立即失败，避免海量文件逐个报错。
2. **并发创建全部目标目录**（含祖先），失败不静默，明确记录错误。
3. **并发删除重复文件**。
4. **并发移动文件**到 `年份/原结构`，同卷移动即 `rename`，**创建日期等元数据保留**。
5. **目标名冲突处理**：
   - 内容相同（先比大小，再比 SHA-256，复用已知哈希避免重算）→ 移除重复源，保留目标；
   - 内容不同 → 自动改名为 `name (1).ext` 并迁移；极端情况回退为随机前缀名。
6. **源文件缺失** → 跳过并继续，不中断整体流程。
7. **空目录清理**：用 POSIX `rmdir` 自底向上清理，只删真空目录，非空（含失败/跳过残留）自动跳过，绝不递归误删。

### 5. 桌面界面
- 上 1/3 配置区：目录选择（文件选择器或直接输入路径，支持 `~` 展开）、开始分析、阶段状态徽章。
- 下 2/3 过程区：三组统计（分析结果 / 排重结果 / 预计处理后）、实时滚动日志、进度条与状态栏。
- 日志按级别着色（信息 / 成功 / 警告 / 错误），可选中复制，自动滚动到最新。
- 忙碌阶段显示「取消」按钮，随时中止。

---

## 二、工作流程

```
选择目录
   ↓
开始分析 → 扫描（遍历文件 + 收集目录）→ 全局排重（按大小分桶 + SHA-256）
   ↓
展示分析结果与「预计处理后」统计，等待确认
   ↓
开始处理 → 建目录 → 删重复 → 移动归档 → 清理空目录
   ↓
完成（或取消 / 失败）
```

阶段状态机：`idle → scanning → hashing → ready → organizing → done`，可转入 `cancelled` / `failed(message)`。

**两段式确认**：分析阶段只读，处理阶段才真正改动磁盘；分析结果确认无误后再点击「开始处理」。

---

## 三、目录结构

```
filereorg/
├── Package.swift                 # SwiftPM 清单（macOS 13+）
├── Sources/FileReorg/
│   ├── FileReorgApp.swift        # App 入口，窗口最小 960×640
│   ├── ContentView.swift         # SwiftUI 界面（配置区 + 过程区 + 日志）
│   ├── OrganizerModel.swift      # 视图模型：阶段状态机、进度节流、日志缓冲、取消
│   └── Core/
│       ├── Models.swift          # 数据模型、错误定义、取消令牌、进度计数器、字节格式化
│       ├── FileScanner.swift     # 目录扫描
│       ├── FileDeduplicator.swift# 全局排重
│       ├── Organizer.swift       # 归档计划器 + 执行器
│       └── Concurrency.swift     # 有界并发 runBounded
├── Tests/FileReorgTests/
│   ├── TestSupport.swift         # 临时目录树构建与断言工具
│   ├── FileScannerTests.swift    # 扫描模块测试（TC1-TC4、TC18）
│   ├── DeduplicatorTests.swift   # 排重模块测试（TC5-TC8、TC19）
│   └── OrganizerTests.swift      # 计划与执行测试（TC9-TC17、TC20-TC21）
├── build/
│   ├── icon/                     # 应用图标绘制脚本与 .icns 产物
│   └── dmg/                      # 打包 staging 目录
└── dist/                         # 构建产物：FileReorg.app、FileReorg-1.1.0.dmg
```

---

## 四、构建与测试

```bash
# 编译
swift build

# Release 编译
swift build -c release

# 运行测试（23 个用例，基于 Swift Testing）
swift test
```

要求：Xcode Command Line Tools 或完整 Xcode，Swift 5.9+。

---

## 五、打包分发

`dist/` 下已包含打包产物 `FileReorg.app` 与 `FileReorg-1.1.0.dmg`。手动重建的参考步骤：

```bash
# 1) Release 编译
swift build -c release

# 2) 组装 .app：Contents/{MacOS,Resources} + Info.plist + AppIcon.icns
#    Bundle Identifier: com.local.filereorg
#    LSMinimumSystemVersion: 13.0

# 3) 签名
codesign --force --deep --sign - dist/FileReorg.app

# 4) 生成 dmg
hdiutil create -volname "FileReorg" -srcfolder build/dmg -ov -format UDZO dist/FileReorg-1.1.0.dmg
```

> 注意：项目未使用 Xcode 工程（`.xcodeproj`），命令行工具链下 SwiftUI 宏不可用，因此界面中的本地视图状态统一放在 `OrganizerModel` 里管理。

---

## 六、核心模块说明

| 模块 | 职责 | 关键接口 |
| --- | --- | --- |
| `FileScanner` | 单次流式遍历，收集文件元数据与目录信息 | `scan(root:progress:cancel:) -> ScanOutcome` |
| `FileDeduplicator` | 大小分桶 + SHA-256 分组排重 | `deduplicate(files:maxConcurrent:progress:cancel:) -> DedupResult` |
| `OrganizerPlanner` | 生成归档计划（纯函数，不落盘） | `makePlan(root:scan:uniqueFiles:deletions:) -> OrganizerPlan` |
| `Organizer` | 执行计划：建目录、删重复、移动、清空目录 | `execute(plan:digests:maxConcurrent:progress:log:cancel:) -> OrganizeResult` |
| `runBounded` | 有界并发执行器，按序收集结果 | `runBounded(count:maxConcurrent:cancel:body:)` |
| `ProgressCounter` | 线程安全计数器，后台写、UI 定时拉取 | `increment/set/value/snapshot` |
| `CancelToken` | 协作式取消令牌（可穿透同步遍历） | `cancel()/reset()/isCancelled` |

---

## 七、设计要点

- **并发有界**：哈希、建目录、删除、移动全部走 `runBounded`，避免海量文件时打满线程或内存。
- **UI 不卡顿**：扫描/排重/执行的重活在 `Task.detached` 后台线程完成；UI 以 0.3 s 节流拉取计数器与日志快照，而非逐条刷新。
- **日志有界**：`LogBuffer` 容量上限 4096 条，界面日志最多保留 400 行，防止极端情况下无界增长。
- **可取消**：`Task.cancel` 无法传播进 `detached` 中的同步遍历，因此额外使用 `CancelToken` 轮询中止；取消时已完成部分保留，需重新分析后才能继续处理。
- **结果确定**：扫描与重复组内部均按相对路径排序，保证同一输入得到同一输出。
- **失败可诊断**：关键错误附带 `NSError.domain#code`，便于定位权限、跨卷、占用等问题。
- **内存管理**：分析完成后只保留唯一文件的哈希，重复文件哈希立即释放；计划执行完毕后释放大对象。

---

## 八、测试覆盖

| 编号 | 内容 |
| --- | --- |
| TC1 | 扫描文件数量与总大小正确 |
| TC2 | 符号链接不计入文件 |
| TC3 | 结果按相对路径排序 |
| TC4 | 空目录被识别 |
| TC5 | 相同内容不同路径归为一组重复 |
| TC6 | 同大小不同内容不误判 |
| TC7 | 重复组保留相对路径排序第一个 |
| TC8 | 浪费空间统计正确 |
| TC9 / TC9b | 目标路径按年份保留原结构；年份目录 4 位数字命名与回退 |
| TC10 | 预计最终目录数计算正确 |
| TC11 | 已在目标位置的文件不移动（幂等） |
| TC12 | 移动与删除按计划完成 |
| TC13 | 移动后创建日期保留 |
| TC14 | 目标冲突：同内容去重 / 异内容改名迁移 |
| TC15 | 源文件缺失跳过且不中断 |
| TC16 | 300 文件并发执行正确性 |
| TC17 | 端到端全链路：统计、目录数与预估完全一致 |
| TC18 | 扫描可取消 |
| TC19 | 排重可取消 |
| TC20 | 处理可取消，文件系统不被改动 |
| TC21 | 空目录自底向上清理，原地保留目录不被清理 |

---

## 九、使用提示

- 处理阶段会**删除重复文件**并**移动原文件**，属于不可逆操作，建议先备份重要数据。
- 目标目录需有写权限；只读卷、外置只读介质会在执行前预检失败并提示。
- 归档依据是**文件创建日期**；若创建日期缺失则回退修改日期，两者皆无则归入 `未知年份`。
- 符号链接不参与处理，避免误删链接目标或产生循环。
- 对同一目录重复执行是安全的：已归档文件会被识别为 `inPlace` 并跳过。
