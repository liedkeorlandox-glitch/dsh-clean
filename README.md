# dsh-clean · dsh-go 清理管家

给 dsh-go 手机 App（proot Ubuntu 环境）用的存储清理工具：**先盘点，再动手**。
分层归因 → 三级风险 → 小步确认 → 隔离可恢复 → 期限 purge。

> 内存（RAM）和存储（磁盘）是两件事：非 Root 杀不了别家进程，本工具只处理可重建的磁盘缓存。

## 组成

| 部分 | 路径 | 说明 |
|---|---|---|
| CLI 管家 | `dsh-clean.sh` | 并行扫描 / 禁动剪枝 / dry-run 默认 / 隔离可恢复 / 期限 purge |
| dsh-go 插件 | `plugins/local-clean/` | 状态条 + 原生面板：看内存磁盘、生成计划、隔离、清空满期项 |

## 安装

```sh
# CLI
cp dsh-clean.sh /usr/local/bin/dsh-clean && chmod +x /usr/local/bin/dsh-clean

# 插件（dsh-go 原生插件，放插件目录后重启 App 生效）
cp -r plugins/local-clean "$DSH_HOME/dsh-go/plugins/"
```

## 用法

```sh
dsh-clean scan [--json]          # 盘点（只读）
dsh-clean plan                   # 生成计划 plan.json
dsh-clean clean                  # dry-run 预览，不动任何文件
dsh-clean clean --yes            # 执行隔离（mv 进隔离区，可恢复）
dsh-clean trash list             # 查看隔离区
dsh-clean trash restore <id>     # 恢复到原路径
dsh-clean trash purge            # 彻底删除满 1 天的隔离项（真正落账）
dsh-clean biggest <dir> [N]      # 目录一层内 TopN 子项
dsh-clean snapshot / diff        # 快照与增量对比（重复盘点更快）
dsh-clean guard <path>           # 删前安全判定
```

## 安全三级

- **SAFE（可重建）**：apt 缓存/索引、npm `_cacache`、`~/.cache/*`、24h 未动的 `/tmp` —— 默认隔离，可恢复。
- **THIN（需勾选）**：`pnpm store prune` 只删无引用包 —— 仅提示，不自动执行。
- **禁动**：插件 `node_modules`、sessions、attachments、profiles、storages、workspace、`/opt` 本体、pnpm store —— 剪枝区不扫不碰。

两条铁律：

1. **隔离 ≠ 释放**：`clean --yes` 后磁盘占用不变，`purge` 才真正落账。
2. **期限保护**：`purge` 未满期一律保留，默认 1 天（`--older-than N` 可调）。

## 设计借鉴

dua-cli（并行扫描 + ignore 剪枝 + 绝不自动删）、trash-cli（FreeDesktop 回收站）、SD Maid（禁动区分级）、npkill（dry-run 默认）。
生态插件：[dsh-storage-insight](https://dsh-plugin.org)、awesome-dsh-plugin 列表。

## 路线图：进 dsh-go 本体

插件先验交互，数据稳定后下沉为原生「设置 → 存储」页：用量环形图 + 三级分类 + 清前预览 + 隔离区恢复 + purge 期限可调。插件与本体共用一份 `plan.json` / `manifest.tsv` 口径，迁移成本最低。

## License

MIT
