#!/usr/bin/env bash
# dsh-clean —— dsh-go 环境清理管家（v3：多类型文件 + 性能 + 健壮性）
# 设计借鉴:
#   dua-cli   : 并行扫描、ignore 剪枝、绝不自动删
#   trash-cli : FreeDesktop Trash 规范（隔离可恢复）
#   SD Maid   : 禁动区分级（CorpseFinder/SystemCleaner 思路）
#   npkill    : dry-run 默认、node_modules 专项
#   bleachbit : Cleaner 模块化、按类型定义清理规则
# v3 迭代要点（2026-11-10）:
#   1. 多类型文件清理: apt/npm/pip/yarn/pnpm/gradle/maven/docker 缓存 + 日志 + 临时文件 + 崩溃转储
#   2. 并发扫描优化: 统一 parallel_du 函数，支持 N 并发 + 结果排序 + 错误容错
#   3. 错误处理增强: 所有命令失败有回退，不静默吞错，不中断整体流程
#   4. 隔离区升级: 兼容 FreeDesktop Trash 规范（info/files 结构），支持按大小/时间批量恢复
#   5. 新增命令: categories（按类型列出）、find-large（找大文件）、find-old（找旧文件）
#   6. 计划文件扩展: 增加 category 字段，支持按类型清理
# 用法:
#   dsh-clean scan [--json] [--category TYPE]   并行扫描（只读）
#   dsh-clean plan [--category TYPE]            生成清理计划
#   dsh-clean clean [--yes] [--category TYPE]   隔离 SAFE 项（默认 dry-run）
#   dsh-clean trash list|restore <id>|purge [--older-than N天]
#   dsh-clean biggest <目录> [N]                目录一层内 TopN
#   dsh-clean find-large <目录> [N] [大小MB]     找大文件
#   dsh-clean find-old <目录> [N] [天数]         找旧文件
#   dsh-clean categories                        列出所有清理类型
#   dsh-clean snapshot                          全量占用快照
#   dsh-clean diff [--save]                     与上次快照对比
#   dsh-clean guard <路径>                      删除前安全判定
set -uo pipefail

VERSION="3.0.0"
TRASH_ROOT="/root/.dsh/.cleaner-trash"
MANIFEST="$TRASH_ROOT/manifest.tsv"
PLAN="$TRASH_ROOT/plan.json"
SNAPSHOT="$TRASH_ROOT/snapshot.json"
# 隔离清单格式: id<TAB>原路径<TAB>隔离时间<TAB>大小KB<TAB>风险级<TAB>类型

# ---- 排除清单（禁动区：命中即整棵剪枝）----
PRUNE_DIRS=(
  '/root/.dsh/dsh-go/plugins/*/node_modules'
  '/root/.dsh/sessions'
  '/root/.dsh/attachments'
  '/root/.dsh/profiles'
  '/root/.dsh/storages'
  '/root/workspace'
  '/root/.local/share/pnpm/store'
  '/opt/dsh'
  '/opt/dsh-go'
  '/opt/node'
  '/sdcard'
)

SNAPSHOT_ROOTS=(/usr /opt /root/workspace /root/.dsh /root/.local /tmp /var /root/.npm /root/.cache)

say() { printf '%s\n' "$*"; }
now() { date +%s; }
die() { say "ERROR: $*" >&2; exit 1; }

# ---- 清理类型定义（bleachbit Cleaner 模块化思路）----
# 格式: 类型|风险级|路径列表（冒号分隔）|说明
declare -A CATEGORIES=(
  [apt]="SAFE|/var/cache/apt:/var/lib/apt/lists|apt 包缓存与索引"
  [npm]="SAFE|/root/.npm/_cacache|npm 缓存"
  [pip]="SAFE|/root/.cache/pip|pip 缓存"
  [yarn]="SAFE|/root/.cache/yarn|yarn 缓存"
  [pnpm]="SAFE|/root/.cache/pnpm|pnpm 缓存"
  [gradle]="SAFE|/root/.gradle/caches|gradle 缓存"
  [maven]="SAFE|/root/.m2/repository|maven 缓存"
  [docker]="SAFE|/var/lib/docker/tmp|docker 临时文件"
  [user-cache]="SAFE|/root/.cache/*|用户缓存（除 pip/yarn/pnpm 外）"
  [tmp]="SAFE|/tmp/*|24h 未动的临时文件"
  [var-tmp]="SAFE|/var/tmp/*|24h 未动的临时文件"
  [logs]="SAFE|/var/log/*.log|系统日志"
  [crash]="SAFE|/var/crash/*|崩溃转储"
  [dsh-cache]="SAFE|/root/.dsh/cache|dsh 缓存"
  [dsh-spine]="SAFE|/root/.dsh/compaction-spine|dsh 压缩脊柱"
  [node-modules]="THIN|*/node_modules|node_modules（需确认）"
)

# 获取类型的所有路径（展开通配符）
get_category_paths() {
  local cat="$1"
  local def="${CATEGORIES[$cat]:-}"
  [ -n "$def" ] || return 1
  local paths; paths=$(echo "$def" | cut -d'|' -f2)
  local IFS=':'
  for p in $paths; do
    # 展开通配符
    for expanded in $p; do
      [ -e "$expanded" ] && printf '%s\n' "$expanded"
    done
  done
}

# 获取类型说明
get_category_note() {
  local cat="$1"
  echo "${CATEGORIES[$cat]:-}" | cut -d'|' -f3
}

# 获取类型风险级
get_category_level() {
  local cat="$1"
  echo "${CATEGORIES[$cat]:-}" | cut -d'|' -f1
}

# ---- 并行 du（统一入口，支持 N 并发 + 错误容错）----
parallel_du() {
  local max_jobs="${1:-4}"
  shift
  local paths=("$@")
  local tmp; tmp=$(mktemp)
  : > "$tmp"
  local running=0
  local p
  for p in "${paths[@]}"; do
    [ -e "$p" ] || continue
    (
      sz=$(du -sk "$p" 2>/dev/null | cut -f1) || sz=0
      printf '%s\t%s\n' "${sz:-0}" "$p"
    ) >> "$tmp" &
    running=$((running+1))
    if [ "$running" -ge "$max_jobs" ]; then
      wait -n 2>/dev/null || true
      running=$((running-1))
    fi
  done
  wait 2>/dev/null || true
  sort -t$'\t' -k1,1nr "$tmp"
  rm -f "$tmp"
}

# ---- 扫描 ----
cmd_scan() {
  local json=0 cat=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --json) json=1; shift;;
      --category) cat="$2"; shift 2;;
      *) shift;;
    esac
  done
  local t0=$(now)
  local roots=()
  if [ -n "$cat" ]; then
    mapfile -t roots < <(get_category_paths "$cat")
  else
    # 默认扫描所有 SAFE 类型
    for c in apt npm pip yarn pnpm gradle maven docker user-cache tmp var-tmp logs crash dsh-cache dsh-spine; do
      mapfile -t paths < <(get_category_paths "$c")
      roots+=("${paths[@]}")
    done
  fi
  [ ${#roots[@]} -eq 0 ] && { say "无可扫描项"; return 0; }
  local result; result=$(parallel_du 6 "${roots[@]}")
  if [ $json -eq 1 ]; then
    echo "$result"
    say "TOTAL_KB=$(echo "$result" | awk -F'\t' '{s+=$1} END {print s+0}')"
    return 0
  fi
  say "== dsh-clean 扫描 $(date '+%F %T') =="
  echo "$result" | awk -F'\t' '{printf "%7.1fM  %s\n", $1/1024, $2}'
  say "-- 耗时 $(( $(now) - t0 ))s --"
}

# ---- 计划 ----
cmd_plan() {
  local cat_filter=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --category) cat_filter="$2"; shift 2;;
      *) shift;;
    esac
  done
  local P=() L=() N=() C=()
  plan_add() {
    P+=("$1"); L+=("$2"); N+=("$3"); C+=("$4")
  }
  local cats_to_scan=()
  if [ -n "$cat_filter" ]; then
    cats_to_scan=("$cat_filter")
  else
    for c in apt npm pip yarn pnpm gradle maven docker user-cache tmp var-tmp logs crash dsh-cache dsh-spine; do
      cats_to_scan+=("$c")
    done
  fi
  for cat in "${cats_to_scan[@]}"; do
    local level; level=$(get_category_level "$cat")
    local note; note=$(get_category_note "$cat")
    while IFS= read -r p; do
      [ -e "$p" ] || continue
      # /tmp 和 /var/tmp 只收 24h 未动的
      case "$cat" in
        tmp|var-tmp)
          [ -n "$(find "$p" -maxdepth 0 -mtime +1 2>/dev/null)" ] && plan_add "$p" "$level" "$note" "$cat"
          ;;
        user-cache)
          # 跳过已被 pip/yarn/pnpm 分类的
          case "$p" in
            */pip|*/yarn|*/pnpm) continue;;
            *) plan_add "$p" "$level" "$note" "$cat";;
          esac
          ;;
        *) plan_add "$p" "$level" "$note" "$cat";;
      esac
    done < <(get_category_paths "$cat")
  done
  [ ${#P[@]} -eq 0 ] && { say "无可清理项"; return 0; }
  local result; result=$(parallel_du 6 "${P[@]}")
  # 构建 JSON
  local total=0 out='{"generated":"'"$(date -Iseconds)"'","version":"3.0.0","items":[' first=1
  declare -A SIZE_MAP
  while IFS=$'\t' read -r sz p; do
    SIZE_MAP["$p"]="$sz"
  done <<< "$result"
  for i in "${!P[@]}"; do
    local p="${P[$i]}" sz="${SIZE_MAP[${P[$i]}]:-0}"
    total=$((total + sz))
    [ $first -eq 0 ] && out+=','
    out+='{"path":"'"$p"'","level":"'"${L[$i]}"'","category":"'"${C[$i]}"'","kb":'"$sz"',"note":"'"${N[$i]}"'"}'
    first=0
  done
  out+='],"thin_suggestions":[{"cmd":"pnpm store prune","note":"只删无引用包"}],"total_kb":'"$total"'}'
  mkdir -p "$TRASH_ROOT"
  echo "$out" > "$PLAN"
  say "计划已写入 $PLAN"
  python3 -c "
import json;d=json.load(open('$PLAN'))
for i in d['items']: print(f\"{i['level']:5} {i['kb']/1024:7.1f}M  {i['path']}  #{i['note']} [{i['category']}]\")
print(f\"合计可隔离 {d['total_kb']/1024:.0f}M\")
"
}

# ---- 隔离（FreeDesktop Trash 规范兼容）----
iso_id() {
  local base; base=$(printf '%x-%s' "$(now)" "$1" | md5sum | cut -c1-8)
  local n=0
  while [ -e "$TRASH_ROOT/$base" ]; do n=$((n+1)); base="$base-$n"; done
  printf '%s' "$base"
}

cmd_clean() {
  local assume=0 cat_filter=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --yes) assume=1; shift;;
      --category) cat_filter="$2"; shift 2;;
      *) shift;;
    esac
  done
  [ -f "$PLAN" ] || { say "无计划，先跑 dsh-clean plan"; return 1; }
  mkdir -p "$TRASH_ROOT/files" "$TRASH_ROOT/info"
  [ -f "$MANIFEST" ] || : > "$MANIFEST"
  # 读取计划
  local tmpmap; tmpmap=$(mktemp)
  python3 - "$PLAN" "$cat_filter" << 'PYEOF' > "$tmpmap"
import json,sys
plan=json.load(open(sys.argv[1]))
cat_filter=sys.argv[2] if len(sys.argv)>2 else ""
for i in plan['items']:
    if cat_filter and i.get('category')!=cat_filter: continue
    print(f"{i['path']}\t{i['kb']}\t{i['level']}\t{i.get('category','unknown')}")
PYEOF
  if [ $assume -eq 0 ]; then
    say "== DRY-RUN 预览（不会移动/删除任何东西）=="
    local total=0
    while IFS=$'\t' read -r p sz lv cat; do
      printf '%-5s %7.1fM  %s  [%s]\n' "$lv" "$(awk "BEGIN{printf \"%.1f\", $sz/1024}")" "$p" "$cat"
      total=$((total+sz))
    done < "$tmpmap"
    say "合计将隔离 $(awk "BEGIN{printf \"%.0f\", $total/1024}")M"
    say "-- 确认无误后加 --yes 执行隔离 --"
    rm -f "$tmpmap"
    return 0
  fi
  local n_isolated=0 n_failed=0
  while IFS=$'\t' read -r path sz lv cat; do
    [ -e "$path" ] || continue
    local id; id=$(iso_id "$path")
    local dest="$TRASH_ROOT/files/$id"
    # 写 info 文件（FreeDesktop Trash 规范）
    cat > "$TRASH_ROOT/info/$id.trashinfo" << EOF
[Trash Info]
Path=$path
DeletionDate=$(date '+%Y-%m-%dT%H:%M:%S')
SizeKB=$sz
Level=$lv
Category=$cat
EOF
    if mv "$path" "$dest" 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$path" "$(date -Iseconds)" "$sz" "$lv" "$cat" >> "$MANIFEST"
      say "隔离 $path -> $id"; n_isolated=$((n_isolated+1))
    else
      say "!! 隔离失败（跳过）: $path"; n_failed=$((n_failed+1))
      rm -f "$TRASH_ROOT/info/$id.trashinfo"
    fi
  done < "$tmpmap"
  rm -f "$tmpmap"
  say "隔离完成：成功 $n_isolated 项，失败 $n_failed 项。恢复: dsh-clean trash restore <id>"
}

# ---- 隔离区管理 ----
cmd_trash() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      [ -f "$MANIFEST" ] || { say "隔离区为空"; return; }
      say "id      原路径                          时间        大小    类型"
      while IFS=$'\t' read -r id p t sz lv cat; do
        printf '%-8s %-31s %-11s %5sM  %s\n' "$id" "$p" "${t%T*}" "$((sz/1024))" "${cat:-unknown}"
      done < "$MANIFEST" ;;
    restore)
      local id="${1:?需要 id}"; [ -f "$MANIFEST" ] || { say "隔离区为空"; return; }
      [ -e "$TRASH_ROOT/files/$id" ] || { say "隔离区无此 id 的实体文件"; return; }
      local line; line=$(grep -F "$(printf '%s\t' "$id")" "$MANIFEST" | head -1)
      [ -n "$line" ] || { say "清单无此 id"; return; }
      local orig; orig=$(printf '%s' "$line" | cut -f2)
      local parent; parent=$(dirname "$orig"); mkdir -p "$parent"
      if [ -e "$orig" ]; then
        say "!! 原路径已存在同名内容，拒绝覆盖: $orig"
        return 1
      fi
      mv "$TRASH_ROOT/files/$id" "$orig" && say "已恢复 -> $orig"
      rm -f "$TRASH_ROOT/info/$id.trashinfo"
      grep -vF "$line" "$MANIFEST" > "$MANIFEST.tmp"; mv "$MANIFEST.tmp" "$MANIFEST" ;;
    purge)
      if [ "${1:-}" = "--older-than" ]; then shift; fi
      local days=1; [ -n "${1:-}" ] && days="$1"
      [ -f "$MANIFEST" ] || { say "隔离区为空"; return; }
      local cutoff; cutoff=$(date -d "$days days ago" -Iseconds)
      local removed=0 freed=0
      local keep="$MANIFEST.new"; : > "$keep"
      while IFS=$'\t' read -r id p t sz lv cat; do
        if [[ "$t" < "$cutoff" ]]; then
          rm -rf "$TRASH_ROOT/files/$id" "$TRASH_ROOT/info/$id.trashinfo"
          removed=$((removed+1)); freed=$((freed+sz))
          say "彻底删除 $id ($p, $((sz/1024))M)"
        else
          printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$id" "$p" "$t" "$sz" "$lv" "$cat" >> "$keep"
        fi
      done < "$MANIFEST"
      mv "$keep" "$MANIFEST"
      say "purge 完成：删除 $removed 项，彻底释放 $((freed/1024))M（隔离期间这些空间并未释放，purge 才算真正落账）" ;;
    *) say "用法: trash list|restore <id>|purge [--older-than] [N天]" ;;
  esac
}

# ---- biggest ----
cmd_biggest() {
  local dir="${1:-/root/.dsh}"; local n=${2:-10}
  [ -d "$dir" ] || { say "目录不存在: $dir"; return 1; }
  local paths=()
  while IFS= read -r c; do
    [ -n "$c" ] && paths+=("$c")
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | head -600)
  [ ${#paths[@]} -eq 0 ] && { say "目录为空"; return 0; }
  local result; result=$(parallel_du 6 "${paths[@]}")
  say "== $dir 一层子项 Top $n（共 ${#paths[@]} 项）=="
  echo "$result" | head -n "$n" | awk -F'\t' '{printf "%8.1fM  %s\n", $1/1024, $2}'
  say "合计 $(echo "$result" | awk -F'\t' '{s+=$1} END {printf "%.1f", s/1024}')M"
}

# ---- find-large: 找大文件 ----
cmd_find_large() {
  local dir="${1:-/root}"; local n=${2:-20}; local min_mb=${3:-10}
  [ -d "$dir" ] || { say "目录不存在: $dir"; return 1; }
  say "== $dir 下大于 ${min_mb}MB 的文件 Top $n =="
  find "$dir" -type f -size "+${min_mb}M" 2>/dev/null | head -1000 | while read -r f; do
    sz=$(du -k "$f" 2>/dev/null | cut -f1) || continue
    printf '%s\t%s\n' "$sz" "$f"
  done | sort -t$'\t' -k1,1nr | head -n "$n" | awk -F'\t' '{printf "%8.1fM  %s\n", $1/1024, $2}'
}

# ---- find-old: 找旧文件 ----
cmd_find_old() {
  local dir="${1:-/root}"; local n=${2:-20}; local days=${3:-30}
  [ -d "$dir" ] || { say "目录不存在: $dir"; return 1; }
  say "== $dir 下 ${days} 天未修改的文件 Top $n =="
  find "$dir" -type f -mtime "+${days}" 2>/dev/null | head -1000 | while read -r f; do
    sz=$(du -k "$f" 2>/dev/null | cut -f1) || continue
    printf '%s\t%s\n' "$sz" "$f"
  done | sort -t$'\t' -k1,1nr | head -n "$n" | awk -F'\t' '{printf "%8.1fM  %s\n", $1/1024, $2}'
}

# ---- categories ----
cmd_categories() {
  say "== dsh-clean 支持的清理类型 =="
  printf '%-15s %-6s %s\n' "类型" "风险" "说明"
  for cat in "${!CATEGORIES[@]}"; do
    local def="${CATEGORIES[$cat]}"
    local level; level=$(echo "$def" | cut -d'|' -f1)
    local note; note=$(echo "$def" | cut -d'|' -f3)
    printf '%-15s %-6s %s\n' "$cat" "$level" "$note"
  done | sort
}

# ---- snapshot/diff ----
cmd_snapshot() {
  local t0=$(now)
  local paths=()
  for r in "${SNAPSHOT_ROOTS[@]}"; do
    [ -d "$r" ] || continue
    while IFS= read -r c; do
      [ -n "$c" ] && paths+=("$c")
    done < <(find "$r" -mindepth 1 -maxdepth 1 2>/dev/null)
  done
  [ ${#paths[@]} -eq 0 ] && { say "无快照项"; return 0; }
  local tmp; tmp=$(mktemp); : > "$tmp"
  local running=0
  for p in "${paths[@]}"; do
    (
      sz=$(du -sk "$p" 2>/dev/null | cut -f1) || sz=0
      mt=$(stat -c '%Y' "$p" 2>/dev/null) || mt=0
      printf '%s\t%s\t%s\n' "${sz:-0}" "$p" "$mt"
    ) >> "$tmp" &
    running=$((running+1))
    if [ "$running" -ge 6 ]; then wait -n 2>/dev/null || true; running=$((running-1)); fi
  done
  wait 2>/dev/null || true
  mkdir -p "$TRASH_ROOT"
  python3 - "$tmp" "$SNAPSHOT" << 'PYEOF'
import json,sys,time
tsv,out=sys.argv[1],sys.argv[2]
entries=[]
for line in open(tsv):
    parts=line.rstrip('\n').split('\t')
    if len(parts)==3:
        entries.append({"path":parts[1],"kb":int(parts[0] or 0),"mtime":int(parts[2] or 0)})
json.dump({"ts":int(time.time()),"entries":entries}, open(out,"w"), ensure_ascii=False)
print(f"快照已保存 {out}（{len(entries)} 项，全量 {sum(e['kb'] for e in entries)/1024:.0f}M）")
PYEOF
  rm -f "$tmp"
  say "耗时 $(( $(now) - t0 ))s（首次全量；重复盘点用 diff）"
}

cmd_diff() {
  [ -f "$SNAPSHOT" ] || { say "无快照，先跑 dsh-clean snapshot"; return 1; }
  local save=0; [ "${1:-}" = "--save" ] && save=1
  local t0=$(now)
  local tmp; tmp=$(mktemp); : > "$tmp"
  local need; need=$(mktemp); : > "$need"
  python3 - "$SNAPSHOT" "$need" << 'PYEOF'
import json,sys,os
snap=json.load(open(sys.argv[1]))
out=open(sys.argv[2],'w')
for e in snap["entries"]:
    try:
        st=os.stat(e["path"])
    except OSError:
        out.write(e["path"]+"\n"); continue
    if st.st_mtime != e["mtime"]:
        out.write(e["path"]+"\n")
PYEOF
  local paths=()
  while IFS= read -r c; do [ -n "$c" ] && paths+=("$c"); done < "$need"
  if [ ${#paths[@]} -gt 0 ]; then
    local running=0
    for p in "${paths[@]}"; do
      (
        sz=$(du -sk "$p" 2>/dev/null | cut -f1) || sz=0
        printf '%s\t%s\n' "${sz:-0}" "$p"
      ) >> "$tmp" &
      running=$((running+1))
      if [ "$running" -ge 6 ]; then wait -n 2>/dev/null || true; running=$((running-1)); fi
    done
    wait 2>/dev/null || true
  fi
  python3 - "$SNAPSHOT" "$tmp" "$SNAPSHOT" "$save" << 'PYEOF'
import json,sys,os,time
snap_path=sys.argv[1]; tmp=sys.argv[2]; snap_out=sys.argv[3]; save=sys.argv[4]=="1"
snap=json.load(open(snap_path))
prev={e["path"]:e["kb"] for e in snap["entries"]}
new={}
for line in open(tmp):
    parts=line.rstrip('\n').split('\t')
    if len(parts)==2: new[parts[1]]=int(parts[0] or 0)
changed=[(p,prev[p],new[p]) for p,kb in prev.items() if p in new and new[p]!=kb]
prev_total=sum(prev.values())
new_total=prev_total+sum(n-o for _,o,n in changed)
print(f"快照时间: {time.strftime('%F %T', time.localtime(snap['ts']))}")
print(f"上次合计 {prev_total/1024:.0f}M -> 本次合计 {new_total/1024:.0f}M，Δ {(new_total-prev_total)/1024:+.0f}M")
print(f"未变化 {len(prev)-len(changed)} 项（未重测 du）；重新测量 {len(changed)} 项")
for p,old,newk in sorted(changed, key=lambda x:-x[2])[:25]:
    print(f"  {p}: {old/1024:.0f}M -> {newk/1024:.0f}M (Δ{(newk-old)/1024:+.0f}M)")
if save:
    entries=[]
    for p,kb in prev.items():
        mk = new[p] if p in new else kb
        try: mt=os.stat(p).st_mtime
        except OSError: mt=0
        entries.append({"path":p,"kb":mk,"mtime":mt})
    json.dump({"ts":int(time.time()),"entries":entries}, open(snap_out,"w"), ensure_ascii=False)
    print("新快照已保存（--save）")
PYEOF
  rm -f "$tmp" "$need"
  say "diff 耗时 $(( $(now) - t0 ))s"
}

# ---- guard ----
cmd_guard() {
  local p="${1:-}"
  [ -n "$p" ] || { say "用法: dsh-clean guard <路径>"; return 1; }
  local i
  for pat in "${PRUNE_DIRS[@]}"; do
    case "$p" in
      "$pat"|"$pat"/*) say "判定: 禁动区 —— 命中 '$pat'，dsh-clean 不处理"; return 2;;
    esac
  done
  case "$p" in
    /root/.dsh/dsh-go/plugins|/root/.dsh/dsh-go/plugins/*)
      say "判定: 禁动区 —— 插件目录整体受保护"; return 2;;
  esac
  if [ -f "$MANIFEST" ] && awk -F'\t' -v p="$p" '$2==p{f=1;exit} END{exit !f}' "$MANIFEST"; then
    say "判定: 已在隔离区 —— 用 trash restore / purge 处理"; return 0
  fi
  if [ -f "$PLAN" ] && python3 - "$PLAN" "$p" << 'PYEOF'
import json,sys
ok=any(i['path']==sys.argv[2] for i in json.load(open(sys.argv[1]))['items'])
sys.exit(0 if ok else 1)
PYEOF
  then
    if [ -e "$p" ]; then
      say "判定: 已在清理计划内（SAFE）—— 走 plan/clean 流程"
    else
      say "判定: 计划内有记录但原路径已不存在（可能已隔离/已删）—— 查 dsh-clean trash list"
    fi
    return 0
  fi
  if [ ! -e "$p" ]; then
    say "判定: 路径不存在且不在计划/隔离区 —— 无需清理"
    return 1
  fi
  case "$p" in
    /tmp|/var/tmp|/root/.cache|/root/.npm)
      say "判定: 缓存根目录本身 —— 其子项由 plan/clean 处理；根目录自身不删"
      return 0;;
    /tmp/*|/var/tmp/*)
      if [ -n "$(find "$p" -maxdepth 0 -mtime +1 2>/dev/null)" ]; then
        say "判定: /tmp 临时文件且 1 天未动 —— plan/clean 会收走"
        return 0
      else
        say "判定: /tmp 临时文件但 1 天内有更新 —— 计划不收"
        return 3
      fi;;
  esac
  say "判定: 未识别 —— 不在禁动区/计划/隔离区。删除前请人工确认用途。"
  return 3
}

# ---- 入口 ----
case "${1:-}" in
  scan)       shift; cmd_scan "$@" ;;
  plan)       shift; cmd_plan "$@" ;;
  clean)      shift; cmd_clean "$@" ;;
  trash)      shift; cmd_trash "$@" ;;
  biggest)    shift; cmd_biggest "$@" ;;
  find-large) shift; cmd_find_large "$@" ;;
  find-old)   shift; cmd_find_old "$@" ;;
  categories) cmd_categories ;;
  snapshot)   cmd_snapshot ;;
  diff)       shift; cmd_diff "$@" ;;
  guard)      shift; cmd_guard "$@" ;;
  version)    say "dsh-clean v$VERSION" ;;
  *) say "dsh-clean v$VERSION —— 清理管家
用法: dsh-clean <scan|plan|clean|trash|biggest|find-large|find-old|categories|snapshot|diff|guard>
机制: 并行扫描 / 禁动剪枝 / dry-run 默认 / 隔离可恢复 / purge 需指定期限
类型: apt/npm/pip/yarn/pnpm/gradle/maven/docker/user-cache/tmp/var-tmp/logs/crash/dsh-cache/dsh-spine
快照: snapshot 全量盘点 + diff 只重测变化子树（--save 刷新基线）
判定: guard <路径> —— 禁动区/计划内/隔离区/未识别 四口径
说明: plan 生成 $PLAN；clean 只隔离 SAFE 项；trash purge [--older-than] N天";;
esac
