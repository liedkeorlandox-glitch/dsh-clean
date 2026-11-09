// local-clean —— 清理管家 v0.3.0
// 状态条显示内存/磁盘可用量；面板支持扫描、按类型清理、隔离区管理、大文件/旧文件查找
// 副作用只在用户点按后发生（plan 扫描只读；隔离进可恢复隔离区；purge 有确认）
import { execFile } from 'node:child_process'
import { promisify } from 'node:util'
import fs from 'node:fs'
import os from 'node:os'

const exec = promisify(execFile)
const CLEAN = '/usr/local/bin/dsh-clean'
const TRASH = '/root/.dsh/.cleaner-trash'

export const name = 'local-clean'

export function apply(ctx) {
  ctx.inject(['dshGo'], (ctx) => {
    const fmt = (b) => (b >= 1024 ** 3 ? (b / 1024 ** 3).toFixed(1) + 'G' : Math.max(1, Math.round(b / 1024 ** 2)) + 'M')

    async function memDisk() {
      const total = os.totalmem()
      const avail = os.freemem()
      let dfree = 0, dtotal = 0
      try {
        const s = await fs.promises.statfs('/')
        dfree = s.bavail * s.bsize
        dtotal = s.blocks * s.bsize
      } catch {}
      return { total, avail, dfree, dtotal }
    }

    const short = (p) => String(p)
      .replace(/^\/var\/lib\/apt\/lists$/, 'apt 索引')
      .replace(/^\/var\/cache\/apt$/, 'apt 缓存')
      .replace(/^\/root\/\.cache\//, '.cache/')
      .replace(/^\/root\/\.npm\//, '.npm/')
      .replace(/^\/root\/\.gradle\//, '.gradle/')
      .replace(/^\/root\/\.m2\//, '.m2/')
      .replace(/^\/root\//, '~/')
      .replace(/^\/tmp\//, 'tmp/')
      .replace(/^\/var\/tmp\//, 'vartmp/')
      .replace(/^\/var\/log\//, 'log/')

    const CATEGORY_LABELS = {
      apt: { zh: 'APT', en: 'APT' },
      npm: { zh: 'NPM', en: 'NPM' },
      pip: { zh: 'PIP', en: 'PIP' },
      yarn: { zh: 'Yarn', en: 'Yarn' },
      pnpm: { zh: 'PNPM', en: 'PNPM' },
      gradle: { zh: 'Gradle', en: 'Gradle' },
      maven: { zh: 'Maven', en: 'Maven' },
      docker: { zh: 'Docker', en: 'Docker' },
      'user-cache': { zh: '用户缓存', en: 'User cache' },
      tmp: { zh: '临时文件', en: 'Temp' },
      'var-tmp': { zh: '系统临时', en: 'Var temp' },
      logs: { zh: '日志', en: 'Logs' },
      crash: { zh: '崩溃转储', en: 'Crash' },
      'dsh-cache': { zh: 'DSH 缓存', en: 'DSH cache' },
      'dsh-spine': { zh: 'DSH 脊柱', en: 'DSH spine' },
      unknown: { zh: '其他', en: 'Other' },
    }

    function catLabel(cat, zh) {
      const l = CATEGORY_LABELS[cat] || CATEGORY_LABELS.unknown
      return zh ? l.zh : l.en
    }

    async function loadPlan() {
      try {
        const j = JSON.parse(await fs.promises.readFile(`${TRASH}/plan.json`, 'utf8'))
        return j
      } catch { return null }
    }

    async function loadTrash() {
      try {
        const lines = (await fs.promises.readFile(`${TRASH}/manifest.tsv`, 'utf8')).split('\n').filter(Boolean)
        return lines.map((l) => {
          const [id, path, time, sz, level, category] = l.split('\t')
          return { id, path, time, kb: Number(sz) || 0, level, category: category || 'unknown' }
        })
      } catch { return [] }
    }

    async function collect(zh) {
      const m = await memDisk()
      const plan = await loadPlan()
      const trash = await loadTrash()

      // 按类型聚合计划
      const byCat = {}
      if (plan?.items) {
        for (const i of plan.items) {
          const c = i.category || 'unknown'
          if (!byCat[c]) byCat[c] = { count: 0, kb: 0 }
          byCat[c].count++
          byCat[c].kb += i.kb || 0
        }
      }
      const catRows = Object.entries(byCat)
        .sort((a, b) => b[1].kb - a[1].kb)
        .slice(0, 6)
        .map(([cat, v]) => ({
          label: catLabel(cat, zh),
          value: `${Math.round(v.kb / 1024)}M`,
          caption: zh ? `${v.count} 项` : `${v.count} items`,
        }))

      // 隔离区统计
      const trashKb = trash.reduce((s, t) => s + t.kb, 0)
      const trashByCat = {}
      for (const t of trash) {
        const c = t.category || 'unknown'
        trashByCat[c] = (trashByCat[c] || 0) + t.kb
      }

      return {
        memAvail: fmt(m.avail),
        memTotal: `${zh ? '共' : 'of'} ${fmt(m.total)}`,
        diskFree: fmt(m.dfree),
        diskUsed: `${zh ? '已用' : 'used'} ${fmt(m.dtotal - m.dfree)}`,
        planTotal: plan ? Math.round((plan.total_kb || 0) / 1024) : 0,
        planCount: plan?.items?.length || 0,
        planTime: plan?.generated ? plan.generated.slice(0, 16).replace('T', ' ') : (zh ? '未生成' : 'Not yet'),
        catRows: catRows.length ? catRows : [{ label: zh ? '暂无数据' : 'No data', value: '0M', caption: zh ? '点扫描开始' : 'Tap Scan' }],
        trashCount: trash.length,
        trashMb: Math.round(trashKb / 1024),
        trashItems: trash.slice(0, 8).map((t) => ({
          title: short(t.path),
          subtitle: `${t.time?.slice(0, 10)} · ${catLabel(t.category, zh)}`,
          trailing: `${Math.round(t.kb / 1024)}M`,
          icon: 'archive',
        })),
        hint: trash.length
          ? (zh ? `隔离区 ${trash.length} 项 / ${Math.round(trashKb / 1024)}M。隔离≠释放，清空满期项才落账` : `Quarantine ${trash.length} items / ${Math.round(trashKb / 1024)}M; purge frees space`)
          : (zh ? '隔离区是空的' : 'Quarantine is empty'),
      }
    }

    // 状态条：每 30s 刷新，点按打开面板
    ctx.dshGo.strip('clean-strip', (scope, emit, caps) => {
      const zh = !String(caps?.locale ?? 'zh').startsWith('en')
      const tick = async () => {
        try {
          const m = await memDisk()
          emit({ text: zh ? `内存${fmt(m.avail)}·磁盘${fmt(m.dfree)}` : `RAM${fmt(m.avail)}·disk${fmt(m.dfree)}` })
        } catch {}
      }
      tick()
      const timer = setInterval(tick, 30_000)
      return () => clearInterval(timer)
    })

    // 面板：v2 视图，指标 + 类型分布 + 隔离区列表 + 操作
    ctx.dshGo.panel('clean', {
      view: (scope, caps) => {
        const zh = !String(caps?.locale ?? 'zh').startsWith('en')
        return {
          v: 2,
          type: 'stack',
          title: zh ? '清理管家' : 'Clean',
          accent: 'teal',
          children: [
            // 顶部指标
            { type: 'row', children: [
              { type: 'metric', label: zh ? '内存可用' : 'RAM free', value: { $: 'data.memAvail' }, caption: { $: 'data.memTotal' } },
              { type: 'metric', label: zh ? '磁盘可用' : 'Disk free', value: { $: 'data.diskFree' }, caption: { $: 'data.diskUsed' } },
            ] },
            // 计划概览
            { type: 'row', children: [
              { type: 'metric', label: zh ? '可隔离' : 'Quarantinable', value: { $: 'data.planTotal' }, caption: { $: 'data.planCount' } },
              { type: 'metric', label: zh ? '隔离区' : 'Quarantined', value: { $: 'data.trashMb' }, caption: { $: 'data.trashCount' } },
            ] },
            // 计划时间
            { type: 'text', text: { $: 'data.planTime' }, style: { size: 'caption' }, tone: 'muted' },
            // 类型分布
            { type: 'text', text: zh ? '按类型分布' : 'By category', style: { size: 'title', weight: 'bold' } },
            { type: 'list', items: { $: 'data.catRows' } },
            // 操作按钮
            { type: 'actions', items: [
              { label: zh ? '扫描' : 'Scan', action: 'scan', style: 'primary', icon: 'search' },
              { label: zh ? '大文件' : 'Large files', action: 'find-large', icon: 'file' },
              { label: zh ? '旧文件' : 'Old files', action: 'find-old', icon: 'history' },
            ] },
            // 隔离区
            { type: 'text', text: zh ? '隔离区' : 'Quarantine', style: { size: 'title', weight: 'bold' } },
            { type: 'text', text: { $: 'data.hint' }, tone: 'muted', style: { size: 'caption' } },
            { type: 'list', items: { $: 'data.trashItems' } },
            // 危险操作
            { type: 'actions', items: [
              { label: zh ? '隔离全部' : 'Quarantine all', action: 'quarantine-all', icon: 'archive' },
              { label: zh ? '清空满期' : 'Purge old', action: 'purge-old', icon: 'delete', style: 'plain' },
            ] },
          ],
        }
      },
      data: (scope, emit, caps) => {
        const zh = !String(caps?.locale ?? 'zh').startsWith('en')
        let alive = true
        const push = async () => {
          if (!alive) return
          try { emit(await collect(zh)) } catch {}
        }
        push()
        const timer = setInterval(push, 60_000)
        return () => { alive = false; clearInterval(timer) }
      },
      actions: {
        scan: () => ({
          pending: { label: '正在扫描可清理项…', timeoutMs: 60_000 },
          result: async (signal) => {
            try {
              await exec(CLEAN, ['plan'], { signal })
              return { toast: '计划已生成', patch: await collect(true) }
            } catch (e) {
              return { toast: e && e.code === 'ENOENT' ? 'dsh-clean 未安装' : '扫描失败或超时' }
            }
          },
        }),
        'find-large': () => ({
          pending: { label: '正在查找大文件…', timeoutMs: 60_000 },
          result: async (signal) => {
            try {
              const { stdout } = await exec(CLEAN, ['find-large', '/root', '15', '10'], { signal })
              return { toast: '大文件查找完成', copy: stdout }
            } catch (e) {
              return { toast: e && e.code === 'ENOENT' ? 'dsh-clean 未安装' : '查找失败' }
            }
          },
        }),
        'find-old': () => ({
          pending: { label: '正在查找旧文件…', timeoutMs: 60_000 },
          result: async (signal) => {
            try {
              const { stdout } = await exec(CLEAN, ['find-old', '/root', '15', '30'], { signal })
              return { toast: '旧文件查找完成', copy: stdout }
            } catch (e) {
              return { toast: e && e.code === 'ENOENT' ? 'dsh-clean 未安装' : '查找失败' }
            }
          },
        }),
        'quarantine-all': () => ({
          pending: { label: '正在隔离缓存…', timeoutMs: 120_000 },
          result: async (signal) => {
            try {
              try { await fs.promises.access(`${TRASH}/plan.json`) } catch { await exec(CLEAN, ['plan'], { signal }) }
              await exec(CLEAN, ['clean', '--yes'], { signal })
              return { toast: '已隔离，空间未释放，清空满期项才落账', patch: await collect(true) }
            } catch (e) {
              return { toast: e && e.code === 'ENOENT' ? 'dsh-clean 未安装' : '隔离失败，看引擎日志' }
            }
          },
        }),
        'purge-old': () => ({
          pending: { label: '正在彻底删除满期项…', timeoutMs: 60_000 },
          result: async (signal) => {
            try {
              await exec(CLEAN, ['trash', 'purge', '--older-than', '1'], { signal })
              return { toast: '满期项已彻底删除', patch: await collect(true) }
            } catch (e) {
              return { toast: e && e.code === 'ENOENT' ? 'dsh-clean 未安装' : '清空失败，看引擎日志' }
            }
          },
        }),
      },
    })
  })
}
