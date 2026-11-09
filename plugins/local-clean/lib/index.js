// local-clean —— 清理管家：状态条显示内存/磁盘可用量，面板里扫描、隔离、清空满期项。
// 副作用只在用户点按后发生（plan 扫描只读；隔离进可恢复的隔离区；purge 有确认）。
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
      .replace(/^\/root\//, '~/')
      .replace(/^\/tmp\//, 'tmp/')

    async function loadRank() {
      try {
        const j = JSON.parse(await fs.promises.readFile(`${TRASH}/plan.json`, 'utf8'))
        const items = (j.items || []).slice(0, 6)
        if (!items.length) return null
        return {
          categories: items.map((i) => short(i.path)),
          values: items.map((i) => Math.round((i.kb / 1024) * 10) / 10),
          caption: `计划可隔离 ${Math.round((j.total_kb || 0) / 1024)}M`,
        }
      } catch { return null }
    }

    async function trashInfo() {
      try {
        const lines = (await fs.promises.readFile(`${TRASH}/manifest.tsv`, 'utf8')).split('\n').filter(Boolean)
        const kb = lines.reduce((s, l) => s + (Number(l.split('\t')[3]) || 0), 0)
        return { n: lines.length, mb: Math.round(kb / 1024) }
      } catch { return { n: 0, mb: 0 } }
    }

    async function collect(zh) {
      const m = await memDisk()
      const rank = await loadRank()
      const t = await trashInfo()
      return {
        memAvail: fmt(m.avail),
        memTotal: `${zh ? '共' : 'of'} ${fmt(m.total)}`,
        diskFree: fmt(m.dfree),
        diskUsed: `${zh ? '已用' : 'used'} ${fmt(m.dtotal - m.dfree)}`,
        rank: rank ?? { categories: [zh ? '暂无数据' : 'no data'], values: [0], caption: zh ? '点「生成清理计划」开始' : 'Tap Plan to start' },
        hint: t.n
          ? (zh ? `隔离区 ${t.n} 项 / ${t.mb}M。隔离≠释放，清空满期项才落账` : `Quarantine ${t.n} items / ${t.mb}M; purge frees space`)
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

    // 面板：指标 + 占用排行 + 动作；隔离和清空都走 confirm，用户确认才动
    ctx.dshGo.panel('clean', {
      view: (scope, caps) => {
        const zh = !String(caps?.locale ?? 'zh').startsWith('en')
        return { type: 'stack', title: zh ? '清理管家' : 'Clean', children: [
          { type: 'row', children: [
            { type: 'metric', label: zh ? '内存可用' : 'RAM free', value: { $: 'data.memAvail' }, caption: { $: 'data.memTotal' } },
            { type: 'metric', label: zh ? '磁盘可用' : 'Disk free', value: { $: 'data.diskFree' }, caption: { $: 'data.diskUsed' } },
          ] },
          { type: 'chart', kind: 'hbar', categories: { $: 'data.rank.categories' }, series: [{ values: { $: 'data.rank.values' } }], unit: 'MB', caption: { $: 'data.rank.caption' } },
          { type: 'text', text: { $: 'data.hint' }, tone: 'muted' },
          { type: 'actions', items: [
            { label: zh ? '生成清理计划' : 'Plan', action: 'plan', style: 'primary', icon: 'search' },
          ] },
          { type: 'confirm', id: 'apply-confirm', confirmLabel: zh ? '确认隔离（可恢复）' : 'Quarantine', cancelLabel: zh ? '先不' : 'Not now' },
          { type: 'confirm', id: 'purge-confirm', confirmLabel: zh ? '彻底删除满期项' : 'Purge old', cancelLabel: zh ? '取消' : 'Cancel' },
        ] }
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
        plan: () => ({
          pending: { label: '正在扫描可清理项…', timeoutMs: 30_000 },
          result: async (signal) => {
            try {
              await exec(CLEAN, ['plan'], { signal })
              return { toast: '计划已生成', patch: await collect(true) }
            } catch (e) {
              return { toast: e && e.code === 'ENOENT' ? 'dsh-clean 未安装' : '扫描失败或超时' }
            }
          },
        }),
        'apply-confirm': (scope, event) => {
          if (!event?.value?.confirmed) return { toast: '已取消' }
          return {
            pending: { label: '正在隔离缓存…', timeoutMs: 60_000 },
            result: async (signal) => {
              try {
                try { await fs.promises.access(`${TRASH}/plan.json`) } catch { await exec(CLEAN, ['plan'], { signal }) }
                await exec(CLEAN, ['clean', '--yes'], { signal })
                return { toast: '已隔离，空间未释放，清空满期项才落账', patch: await collect(true) }
              } catch (e) {
                return { toast: e && e.code === 'ENOENT' ? 'dsh-clean 未安装' : '隔离失败，看引擎日志' }
              }
            },
          }
        },
        'purge-confirm': (scope, event) => {
          if (!event?.value?.confirmed) return { toast: '已取消' }
          return {
            pending: { label: '正在彻底删除满期项…', timeoutMs: 60_000 },
            result: async (signal) => {
              try {
                await exec(CLEAN, ['trash', 'purge', '--older-than', '1'], { signal })
                return { toast: '满期项已彻底删除', patch: await collect(true) }
              } catch (e) {
                return { toast: e && e.code === 'ENOENT' ? 'dsh-clean 未安装' : '清空失败，看引擎日志' }
              }
            },
          }
        },
      },
    })
  })
}
