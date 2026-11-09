# 原生独立存储清理（无 AI / 无引擎）

本目录是把清理从「模型调用插件」变为「dsh-go App 本体功能」的实现。核心在 Android 原生 Kotlin，Flutter 只做界面；DSH 引擎停止或未安装也能使用。

## 已实现

- `android/storage/StorageCleaner.kt`：固定白名单缓存分类（apt/npm/pip/yarn/pnpm/gradle/maven/dsh-cache/tmp/var-tmp/user-cache），递归统计、临时目录整棵树满 24h 才收、符号链接不跟随、取消即时生效。
- 隔离：`App filesDir/storage-clean/trash/{files,info}`，每条带唯一 UUID 和原始相对路径、类型、时间、大小；info 先写、move 后做，失败回滚整批。
- 隔离操作整批失败回滚；恢复拒绝覆盖原路径；永久删除至少保留 1 天；restore 校验 id 与路径不逃逸 rootfs。
- 永久排除会话、附件、profiles、storages、workspace、插件、程序本体、pnpm store 和 `/sdcard`。
- `StorageCleanerPlugin.kt`：`dsh/storage_cleaner` MethodChannel，单线程执行，支持取消；无任何 shell、网络、DSH 或模型调用。
- `flutter/storage_cleaner_page.dart`：用上游真实的 `AppPage.list` / `SettingsSection` / `SettingsTile` 骨架；分类勾选、扫描、隔离确认、恢复、满期清理确认；import 路径已对齐 `app/lib/ui/settings/` 的真实相对路径。

## 接入上游所需补丁（已核对上游 main 实际代码）

1. `MainActivity.provideFlutterEngine` 的插件注册链（`engine.plugins.add(...)` 那串）追加：
   ```kotlin
   engine.plugins.add(io.github.ccch1mneyyy.dsh_app.storage.StorageCleanerPlugin())
   ```
2. 两个 Kotlin 文件放到 `app/android/app/src/main/kotlin/io/github/ccch1mneyyy/dsh_app/storage/`。
3. Dart 页面放到 `app/lib/ui/settings/storage_cleaner_page.dart`（import 已按该位置写好）。
4. `settings/index/settings_pages.dart` 导入该页面，`settingsPage` 的 switch 增加 `SettingsPageId.storageCleaner => const StorageCleanerPage()`。
5. `settings/index/spots.dart` 的 enum 加 `storageCleaner`，并添加对应 `SettingsPageMeta`（标题、general 分组、链接 `storage`）。
6. `settings_screen.dart` 在「通用」分组（PerformanceSettingsTile 附近）增加 `SettingsTile` 打开 `StorageCleanerPage()`。
7. 在 `lib/l10n/parts/` 增加 ARB 词条并跑 `tool/l10n_merge.py`；当前页面用 locale 判断的中英文案可先工作，正式合并时迁移到 `context.l10n`。

## 测试与当前验证边界

- 本机没有 `flutter`、`dart`、`kotlinc`、`gradle`、`java`，因此完成的是源码实现与静态审查（import/API 均对照上游 main 真实文件核对），未宣称 Android 编译或 Flutter 运行通过。
- 需要 Android 单元测试：符号链接、满期边界、嵌套新文件使 tmp 不收、批量失败回滚、恢复拒绝覆盖、purge 保留期、恶意 id/path 拒绝。
- 需要 Flutter widget 测试：空列表、扫描失败、勾选隔离、确认/取消、恢复、满期清理。
- 必须真机验证：引擎停止时可扫描；隔离前后磁盘占用不变；purge 后才释放；取消操作不产生孤儿项。

此交付按用户要求跳过 PR；完整代码在 `liedkeorlandox-glitch/dsh-clean` 仓库。

