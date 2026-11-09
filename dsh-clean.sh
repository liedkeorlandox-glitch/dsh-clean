#!/usr/bin/env bash
# dsh-clean —— dsh-go 环境清理管家（v2：效率 + 准确性迭代）
# 设计借鉴: dua-cli(并行扫描+ignore 剪枝+绝不自动删) / trash-cli(隔离可恢复) / SD Maid(排除分级) / npkill(dry-run)
# v2 迭代依据（2026-11-09 会话日志分析）:
#   * 全量 du 单次 31s：新增 snapshot/diff，重复盘点时未变化子树只 stat 不重测
#   * 顶层子项逐个 du 的临时探测 20+ 次/轮：新增 biggest 单次并行 TopN
#   * 归因口径反复修正（保留集 39M->186M）：新增 guard 统一判定口径 + 计划大小复用
#   * 结果体量偏大挤占上下文：scan --json / biggest 双态输出控制
# 用法:
#   dsh-clean scan [--json]              并行扫描可清理项（只读）
#   dsh-clean plan                       生成清理计划 JSON（各条目并行量化）
#   dsh-clean clean [--yes]              隔离 SAFE 项（默认 dry-run 预览）
#   dsh-clean trash list|restore <id>|purge [--older-than] [N天]
#   dsh-clean biggest <目录> [N]         目录一层内 TopN 最大子项（单次并行测量）
#   dsh-clean snapshot                   全量占用快照（App 环境根）
#   dsh-clean diff [--save]              与上次快照对比（只重测变化子树）
#   dsh-clean guard <路径>               删除/清理前安全判定
set -uo pipefail

TRASH_ROOT="/root/.dsh/.cleaner-trash"
MANIFEST="$TRASH_ROOT/manifest.tsv"
PLAN="$TRASH_ROOT/plan.json"
SNAPSHOT="$TRASH_ROOT/snapshot.json"
# 隔离清单格式: id<TAB>原路径<TAB>隔离时间<TAB>大小字节<TAB>风险级

# ---- 排除清单（dua 式：命中即整棵剪枝，绝不进入扫描队列）----
# 禁动区：插件依赖/会话/附件/workspace/程序本体 —— 一律不扫不碰
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

# snapshot 根：App 环境目录（不扫 /sdcard——那是用户手机存储，df 只看总量即可）
SNAPSHOT_ROOTS=(/usr /opt /root/workspace /root/.dsh /root/.local /tmp /var /root/.npm /root/.cache)

say() { printf '%s\n' "$*"; }
now() { date +%s; }

# 注意：PRUNE_DIRS 是"禁动区"声明——scan/plan 的扫描根是白名单制（只扫下面列的缓存根），
# 天然不会触及禁动区；PRUNE_DIRS 用于全盘扫描时的 find 剪枝与 guard 判定。

# 生成 find 剪枝表达式（扩展全盘扫描时使用；当前白名单扫描用不到，保留备查）
build_prune_expr() {
  local expr=()
  for p in "${PRUNE_DIRS[@]}"; do expr+=(-path "$p" -prune -o); done
  echo "${expr[@]}"
}

# ---- 并行扫描（dua 式：多目录并发；白名单根，禁动区不在名单内等于剪枝）----
cmd_scan() {
  local json=0; [ "${1:-}" = "--json" ] && json=1
  local t0=$(now)
  local roots=(/var/cache/apt /var/lib/apt/lists /root/.cache /root/.npm /tmp
               /root/.dsh/compaction-spine /root/.dsh/cache /var/log /var/tmp)
  local tmp; tmp=$(mktemp); : > "$tmp"
  local pids=() r
  for r in "${roots[@]}"; do
    [ -d "$r" ] || continue
    ( sz=$(du -sk "$r" 2>/dev/null | cut -f1); printf '%s\t%s\n' "${sz:-0}" "$r"; ) >> "$tmp" &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null || true
  if [ $json -eq 1 ]; then
    sort -t$'\t' -k1,1nr "$tmp"
    say "TOTAL_KB=$(awk -F'\t' '{s+=$1} END {print s+0}' "$tmp")"
    rm -f "$tmp"
    return 0
  fi
  say "== dsh-clean 扫描 $(date '+%F %T') =="
  awk -F'\t' '{printf "%7.1fM  %s\n", $1/1024, $2}' "$tmp"
  rm -f "$tmp"
  say "-- 耗时 $(( $(now) - t0 ))s，注：以上为并行输出，顺序不固定 --"
}

# ---- 风险分级 + 计划（v2：候选先收集，du 全部并行，告别串行逐个量）----
# SAFE   : 可重建缓存，隔离无副作用，clean 会处理
# THIN   : 瘦身类（只建议不自动动，如 pnpm store prune）
# 禁动区 : PRUNE_DIRS 列出的插件/会话/附件/workspace/程序本体，计划永远不含
cmd_plan() {
  local P=() L=() N=()
  plan_add() { P+=("$1"); L+=("$2"); N+=("$3"); }
  plan_add /var/cache/apt SAFE "apt 包缓存"
  plan_add /var/lib/apt/lists SAFE "apt 索引"
  [ -d /root/.npm/_cacache ] && plan_add /root/.npm/_cacache SAFE "npm 缓存"
  for d in /root/.cache/*; do [ -e "$d" ] && plan_add "$d" SAFE "用户缓存"; done
  # /tmp 子项单列（24h 未动才算可清；跳过本工具自身的工作文件）
  for d in /tmp/*; do
    [ -e "$d" ] || continue
    case "$d" in /tmp/dsh-clean*) continue;; esac
    [ -n "$(find "$d" -maxdepth 0 -mtime +1 2>/dev/null)" ] && plan_add "$d" SAFE "24h 未动的临时文件"
  done
  [ ${#P[@]} -eq 0 ] && { say "无可清理项"; return 0; }
  local tmp; tmp=$(mktemp); : > "$tmp"
  local pids=() i
  for i in "${!P[@]}"; do
    ( sz=$(du -sk "${P[$i]}" 2>/dev/null | cut -f1);
      printf '%s\t%s\t%s\t%s\n' "${sz:-0}" "${P[$i]}" "${L[$i]}" "${N[$i]}"; ) >> "$tmp" &
    pids+=($!)
  done
  wait "${pids[@]}" 2>/dev/null || true
  local total=0 out='{"generated":"'"$(date -Iseconds)"'","items":[' first=1 line sz p lv nt
  while IFS=$'\t' read -r sz p lv nt; do
    [ -z "${p:-}" ] && continue
    total=$((total + ${sz:-0}))
    [ $first -eq 0 ] && out+=','
    out+='{"path":"'"$p"'","level":"'"$lv"'","kb":'"${sz:-0}"',"note":"'"$nt"'"}'
    first=0
  done < "$tmp"
  rm -f "$tmp"
  out+='],"thin_suggestions":[{"cmd":"pnpm store prune","note":"只删无引用包"}],"total_kb":'"$total"'}'
  echo "$out" > "$PLAN"
  say "计划已写入 $PLAN"
  python3 -c "
import json;d=json.load(open('$PLAN'))
for i in d['items']: print(f\"{i['level']:5} {i['kb']/1024:7.1f}M  {i['path']}  #{i['note']}\")
print(f\"合计可隔离 {d['total_kb']/1024:.0f}M\")
"
}

# ---- 隔离（trash-cli 式：移入隔离区+登记原路径，可恢复）----
# 同一秒同一路径可能撞 id，追加计数后缀兜底
iso_id() {
  local base; base=$(printf '%x-%s' "$(now)" "$1" | md5sum | cut -c1-8)
  local n=0
  while [ -e "$TRASH_ROOT/$base" ]; do n=$((n+1)); base="$base-$n"; done
  printf '%s' "$base"
}

cmd_clean() {
  local assume=0; [ "${1:-}" = "--yes" ] && { assume=1; shift; }
  [ -f "$PLAN" ] || { say "无计划，先跑 dsh-clean plan"; return 1; }
  # v2：计划里的大小直接复用，不再搬完后对每个隔离项重测 du
  local tmpmap; tmpmap=$(mktemp)
  python3 - "$PLAN" << 'PYEOF' > "$tmpmap"
import json,sys
for i in json.load(open(sys.argv[1]))['items']:
    print(f"{i['path']}\t{i['kb']}")
PYEOF
  declare -A PSIZE
  while IFS=$'\t' read -r p k; do [ -n "${p:-}" ] && PSIZE["$p"]=$k; done < "$tmpmap"
  rm -f "$tmpmap"
  mkdir -p "$TRASH_ROOT"
  [ -f "$MANIFEST" ] || : > "$MANIFEST"
  if [ $assume -eq 0 ]; then
    say "== DRY-RUN 预览（不会移动/删除任何东西）=="
    python3 -c "
import json
d = json.load(open('$PLAN'))
for i in d['items']:
    print(f\"{i['level']:5} {i['kb']/1024:7.1f}M  {i['path']}  #{i['note']}\")
print(f'合计将隔离 {d[\"total_kb\"]/1024:.0f}M')"
    say "-- 确认无误后加 --yes 执行隔离 --"
    return 0
  fi
  python3 - "$PLAN" << 'PYEOF' > "$TRASH_ROOT/.batch.tmp"
import json,sys
for i in json.load(open(sys.argv[1]))['items']:
    if i['level']=='SAFE': print(i['path'])
PYEOF
  mv "$TRASH_ROOT/.batch.tmp" "$TRASH_ROOT/.batch"
  local n_isolated=0 n_failed=0
  while IFS= read -r path; do
    [ -e "$path" ] || continue
    local id; id=$(iso_id "$path")
    local dest="$TRASH_ROOT/$id"
    # 隔离后大小以计划为准；计划缺失时退回 du
    local sz="${PSIZE[$path]:-$(du -sk "$dest" 2>/dev/null | cut -f1)}"
    if mv "$path" "$dest" 2>/dev/null; then
      printf '%s\t%s\t%s\t%s\tSAFE\n' "$id" "$path" "$(date -Iseconds)" "${sz:-0}" >> "$MANIFEST"
      say "隔离 $path -> $id"; n_isolated=$((n_isolated+1))
    else
      say "!! 隔离失败（跳过，不中断）: $path"; n_failed=$((n_failed+1))
    fi
  done < "$TRASH_ROOT/.batch"
  rm -f "$TRASH_ROOT/.batch"
  say "隔离完成：成功 $n_isolated 项，失败 $n_failed 项。恢复: dsh-clean trash restore <id>"
}

# ---- 隔离区管理 ----
cmd_trash() {
  local sub="${1:-list}"; shift || true
  case "$sub" in
    list)
      [ -f "$MANIFEST" ] || { say "隔离区为空"; return; }
      say "id      原路径                          时间        大小"
      while IFS=$'\t' read -r id p t sz lv; do
        printf '%-8s %-31s %-11s %sM\n' "$id" "$p" "${t%T*}" "$((sz/1024))"
      done < "$MANIFEST" ;;
    restore)
      local id="${1:?需要 id}"; [ -f "$MANIFEST" ] || { say "隔离区为空"; return; }
      [ -e "$TRASH_ROOT/$id" ] || { say "隔离区无此 id 的实体文件"; return; }
      local line; line=$(grep -F "$(printf '%s\t' "$id")" "$MANIFEST" | head -1)
      [ -n "$line" ] || { say "清单无此 id（可能是历史残留实体，手工处理: mv $TRASH_ROOT/$id <原路径>）"; return; }
      local orig; orig=$(printf '%s' "$line" | cut -f2)
      local parent; parent=$(dirname "$orig"); mkdir -p "$parent"
      if [ -e "$orig" ]; then
        say "!! 原路径已存在同名内容，拒绝覆盖: $orig"
        return 1
      fi
      mv "$TRASH_ROOT/$id" "$orig" && say "已恢复 -> $orig"
      grep -vF "$line" "$MANIFEST" > "$MANIFEST.tmp"; mv "$MANIFEST.tmp" "$MANIFEST" ;;
    purge)
      if [ "${1:-}" = "--older-than" ]; then shift; fi   # 兼容 --older-than N 写法
      local days=1; [ -n "${1:-}" ] && days="$1"
      [ -f "$MANIFEST" ] || { say "隔离区为空"; return; }
      local cutoff; cutoff=$(date -d "$days days ago" -Iseconds)
      local removed=0 freed=0
      local keep="$MANIFEST.new"; : > "$keep"
      while IFS=$'\t' read -r id p t sz lv; do
        if [[ "$t" < "$cutoff" ]]; then
          rm -rf "$TRASH_ROOT/$id"; removed=$((removed+1)); freed=$((freed+sz))
          say "彻底删除 $id ($p, $((sz/1024))M)"
        else
          printf '%s\t%s\t%s\t%s\t%s\n' "$id" "$p" "$t" "$sz" "$lv" >> "$keep"
        fi
      done < "$MANIFEST"
      mv "$keep" "$MANIFEST"
      say "purge 完成：删除 $removed 项，彻底释放 $((freed/1024))M（隔离期间这些空间并未释放，purge 才算真正落账）" ;;
    *) say "用法: trash list|restore <id>|purge [天数]" ;;
  esac
}

# ---- v2: biggest —— 目录一层内 TopN 最大子项（一次并行测量，替代逐个临时 du）----
cmd_biggest() {
  local dir="${1:-/root/.dsh}"; local n=${2:-10}
  [ -d "$dir" ] || { say "目录不存在: $dir"; return 1; }
  local tmp; tmp=$(mktemp); : > "$tmp"
  local pids=() c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    ( sz=$(du -sk "$c" 2>/dev/null | cut -f1); printf '%s\t%s\n' "${sz:-0}" "$c"; ) >> "$tmp" &
    pids+=($!)
  done < <(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | head -600)
  wait "${pids[@]}" 2>/dev/null || true
  say "== $dir 一层子项 Top $n（单次并行测量，共 $(wc -l < "$tmp") 项）=="
  sort -t$'\t' -k1,1nr "$tmp" | head -n "$n" | awk -F'\t' '{printf "%8.1fM  %s\n", $1/1024, $2}'
  say "合计 $(awk -F'\t' '{s+=$1} END {printf "%.1f", s/1024}' "$tmp")M"
  rm -f "$tmp"
}

# ---- v2: snapshot/diff —— 全量盘点的两次测量只差"变化的部分" ----
cmd_snapshot() {
  local t0=$(now)
  local tmp; tmp=$(mktemp); : > "$tmp"
  local pids=() r c
  for r in "${SNAPSHOT_ROOTS[@]}"; do
    [ -d "$r" ] || continue
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      ( sz=$(du -sk "$c" 2>/dev/null | cut -f1); mt=$(stat -c '%Y' "$c" 2>/dev/null);
        printf '%s\t%s\t%s\n' "${sz:-0}" "$c" "$mt"; ) >> "$tmp" &
      pids+=($!)
    done < <(find "$r" -mindepth 1 -maxdepth 1 2>/dev/null)
  done
  wait "${pids[@]}" 2>/dev/null || true
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
import json,sys
snap=json.load(open(sys.argv[1]))
out=open(sys.argv[2],'w')
for e in snap["entries"]:
    try:
        import os; st=os.stat(e["path"])
    except OSError:
        out.write(e["path"]+"\n"); continue
    if st.st_mtime != e["mtime"]:
        out.write(e["path"]+"\n")
PYEOF
  local pids=() c
  while IFS= read -r c; do
    [ -n "$c" ] || continue
    ( sz=$(du -sk "$c" 2>/dev/null | cut -f1); printf '%s\t%s\n' "${sz:-0}" "$c"; ) >> "$tmp" &
    pids+=($!)
  done < "$need"
  wait "${pids[@]}" 2>/dev/null || true
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

# ---- v2: guard —— 删除/清理前统一口径判定 ----
cmd_guard() {
  local p="${1:-}"
  [ -n "$p" ] || { say "用法: dsh-clean guard <路径>"; return 1; }
  local i
  for pat in "${PRUNE_DIRS[@]}"; do
    case "$p" in
      "$pat"|"$pat"/*) say "判定: 禁动区 —— 命中 '$pat'，dsh-clean 不处理"; return 2;;
    esac
  done
  # 插件目录整体禁动（不只是 node_modules）：dsh-go/plugins 下的代码与依赖均线性保留
  case "$p" in
    /root/.dsh/dsh-go/plugins|/root/.dsh/dsh-go/plugins/*)
      say "判定: 禁动区 —— 插件目录整体受保护（含 *.js 与 node_modules），dsh-clean 不处理"; return 2;;
  esac
  # 隔离区优先：在这些动过的东西先看隔离区，而不是计划
  if [ -f "$MANIFEST" ] && awk -F'\t' -v p="$p" '$2==p{f=1;exit} END{exit !f}' "$MANIFEST"; then
    say "判定: 已在隔离区 —— 用 trash restore / purge 处理"; return 0
  fi
  # 计划判定：区分"还在原位"与"原路径已不存在"（后者可能是已隔离/已删的历史条目）
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

case "${1:-}" in
  scan)     shift; cmd_scan "$@" ;;
  plan)     cmd_plan ;;
  clean)    shift; cmd_clean "$@" ;;
  trash)    shift; cmd_trash "$@" ;;
  biggest)  shift; cmd_biggest "$@" ;;
  snapshot) cmd_snapshot ;;
  diff)     shift; cmd_diff "$@" ;;
  guard)    shift; cmd_guard "$@" ;;
  *) say "dsh-clean v2 —— 清理管家
用法: dsh-clean <scan|plan|clean|trash|biggest|snapshot|diff|guard>
机制: 并行扫描 / 禁动剪枝 / dry-run 默认 / 隔离可恢复 / purge 需指定期限
快照: snapshot 全量盘点 + diff 只重测变化子树（--save 刷新基线）
判定: guard <路径> —— 禁动区/计划内/隔离区/未识别 四口径
说明: plan 生成 $PLAN；clean 只隔离 SAFE 项；trash purge [--older-than] N天";;
esac
