'use client'

export const dynamic = 'force-dynamic'

import { useEffect, useState, useCallback, useMemo } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

const ADMIN_ROLES = ['operator_admin', 'superadmin', 'manager']

type GroupBy = 'product' | 'machine' | 'none'

interface Machine { machine_id: string; official_name: string }
interface BoonzProduct { product_id: string; boonz_product_name: string }
interface PodProduct { pod_product_id: string; pod_product_name: string }

interface MappingRow {
  mapping_id: string
  pod_product_id: string
  pod_product_name: string
  boonz_product_id: string
  boonz_product_name: string
  machine_id: string | null
  machine_name: string | null
  split_pct: number
  status: string
}

interface PodGroup {
  pod_product_id: string
  pod_product_name: string
  total_pct: number
  split_count: number
}

interface MachineSection {
  machine_id: string | null
  machine_name: string
  pod_groups: PodGroup[]
}

interface SplitDraft {
  key: string
  mapping_id: string | null
  original_boonz_id: string | null   // boonz_product_id as loaded from DB; null for new rows
  boonz_product_id: string
  split_pct: number
  toDelete: boolean
}

interface RawRow {
  mapping_id: string
  pod_product_id: string
  boonz_product_id: string
  machine_id: string | null
  split_pct: number
  status: string
  pod_products: { pod_product_name: string }
  boonz_products: { boonz_product_name: string }
  machines: { official_name: string } | null
}

let _k = 0
const nk = () => `k${++_k}`
const aKey = (podId: string, machineId: string | null) => `${podId}|||${machineId ?? '__global__'}`

export default function ProductMappingPage() {
  const router = useRouter()

  const [authed, setAuthed] = useState(false)
  const [loadingRef, setLoadingRef] = useState(true)
  const [loadingMaps, setLoadingMaps] = useState(false)

  const [machines, setMachines] = useState<Machine[]>([])
  const [boonzProducts, setBoonzProducts] = useState<BoonzProduct[]>([])
  const [podProducts, setPodProducts] = useState<PodProduct[]>([])
  const [mappings, setMappings] = useState<MappingRow[]>([])

  const [groupBy, setGroupBy] = useState<GroupBy>('product')
  const [selectedMachineId, setSelectedMachineId] = useState<string | null>(null)
  const [search, setSearch] = useState('')

  // Accordion — compound key: podId|||machineId
  const [expandedKey, setExpandedKey] = useState<string | null>(null)
  const [splitDrafts, setSplitDrafts] = useState<Record<string, SplitDraft[]>>({})
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)

  // Bulk apply
  const [bulkOpen, setBulkOpen] = useState(false)
  const [bulkSelected, setBulkSelected] = useState<Set<string>>(new Set())
  const [bulkConfirm, setBulkConfirm] = useState(false)
  const [bulkSaving, setBulkSaving] = useState(false)

  // Add modal
  const [showAdd, setShowAdd] = useState(false)
  const [addPodId, setAddPodId] = useState('')
  const [addPodSearch, setAddPodSearch] = useState('')
  const [addMachineId, setAddMachineId] = useState('__global__')
  const [addSplits, setAddSplits] = useState<{ key: string; boonz_product_id: string; split_pct: number }[]>([])
  const [addError, setAddError] = useState<string | null>(null)
  const [adding, setAdding] = useState(false)
  const [addLoadingExisting, setAddLoadingExisting] = useState(false)
  const [addIsUpdate, setAddIsUpdate] = useState(false)

  // ── Auth + reference data ──────────────────────────────────────────────────
  useEffect(() => {
    async function init() {
      const supabase = createClient()
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) { router.push('/login'); return }
      const { data: profile } = await supabase.from('user_profiles').select('role').eq('id', user.id).single()
      if (!profile || !ADMIN_ROLES.includes(profile.role)) { router.push('/field'); return }

      // FIX 1: fetch ALL machines (no status filter) so dropdown always populates
      const [{ data: mData }, { data: bData }, { data: ppData }] = await Promise.all([
        supabase.from('machines').select('machine_id, official_name').order('official_name'),
        supabase.from('boonz_products').select('product_id, boonz_product_name').order('boonz_product_name'),
        supabase.from('pod_products').select('pod_product_id, pod_product_name').order('pod_product_name'),
      ])
      if (mData) {
        setMachines(mData)
        if (mData.length > 0) {
          setSelectedMachineId(mData[0].machine_id)
          setAddMachineId(mData[0].machine_id)
        }
      }
      if (bData) setBoonzProducts(bData)
      if (ppData) setPodProducts(ppData)
      setLoadingRef(false)
      setAuthed(true)
    }
    init()
  }, [router])

  // ── Load ALL mappings (no machine filter — grouping is client-side) ─────────
  const loadMappings = useCallback(async () => {
    setLoadingMaps(true)
    setExpandedKey(null)
    setSplitDrafts({})
    setSaveError(null)
    const supabase = createClient()
    const sel = 'mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, status, pod_products!inner(pod_product_name), boonz_products!inner(boonz_product_name), machines(official_name)'
    const { data } = await supabase.from('product_mapping').select(sel).order('pod_product_id')
    const rawData = (data ?? []) as unknown as RawRow[]

    // Deduplicate by mapping_id
    const seen = new Set<string>()
    const rows: MappingRow[] = []
    for (const r of rawData) {
      if (seen.has(r.mapping_id)) continue
      seen.add(r.mapping_id)
      rows.push({
        mapping_id: r.mapping_id,
        pod_product_id: r.pod_product_id,
        pod_product_name: r.pod_products.pod_product_name,
        boonz_product_id: r.boonz_product_id,
        boonz_product_name: r.boonz_products.boonz_product_name,
        machine_id: r.machine_id,
        machine_name: r.machines?.official_name ?? null,
        split_pct: r.split_pct ?? 0,
        status: r.status ?? 'Active',
      })
    }
    setMappings(rows)
    setLoadingMaps(false)
  }, [])

  useEffect(() => { if (authed) loadMappings() }, [authed, loadMappings])

  // ── useMemo: By Product (filtered to selected machine) ────────────────────
  const byProductGroups = useMemo<PodGroup[]>(() => {
    const rows = selectedMachineId === null
      ? mappings.filter(r => r.machine_id === null && r.status === 'Active')
      : mappings.filter(r => r.machine_id === selectedMachineId && r.status === 'Active')
    const map = new Map<string, PodGroup>()
    for (const r of rows) {
      const g = map.get(r.pod_product_id)
      if (g) { g.total_pct += r.split_pct; g.split_count++ }
      else map.set(r.pod_product_id, { pod_product_id: r.pod_product_id, pod_product_name: r.pod_product_name, total_pct: r.split_pct, split_count: 1 })
    }
    return [...map.values()].sort((a, b) => a.pod_product_name.localeCompare(b.pod_product_name))
  }, [mappings, selectedMachineId])

  const filteredProductGroups = useMemo(() => {
    if (!search.trim()) return byProductGroups
    const q = search.toLowerCase()
    return byProductGroups.filter(g => g.pod_product_name.toLowerCase().includes(q))
  }, [byProductGroups, search])

  // ── useMemo: By Machine ───────────────────────────────────────────────────
  const byMachineGroups = useMemo<MachineSection[]>(() => {
    const machineMap = new Map<string, { machine_id: string | null; machine_name: string; pods: Map<string, PodGroup> }>()
    for (const r of mappings.filter(m => m.status === 'Active' && m.machine_id !== null)) {
      const key = r.machine_id ?? '__global__'
      if (!machineMap.has(key)) {
        machineMap.set(key, {
          machine_id: r.machine_id,
          machine_name: r.machine_id === null ? 'Global (all machines)' : (r.machine_name ?? r.machine_id),
          pods: new Map(),
        })
      }
      const section = machineMap.get(key)!
      const g = section.pods.get(r.pod_product_id)
      if (g) { g.total_pct += r.split_pct; g.split_count++ }
      else section.pods.set(r.pod_product_id, { pod_product_id: r.pod_product_id, pod_product_name: r.pod_product_name, total_pct: r.split_pct, split_count: 1 })
    }
    const sections: MachineSection[] = [...machineMap.values()].map(s => ({
      machine_id: s.machine_id,
      machine_name: s.machine_name,
      pod_groups: [...s.pods.values()].sort((a, b) => a.pod_product_name.localeCompare(b.pod_product_name)),
    }))
    // A→Z by machine name (no global section)
    sections.sort((a, b) => a.machine_name.localeCompare(b.machine_name))
    return sections
  }, [mappings])

  const filteredMachineSections = useMemo(() => {
    if (!search.trim()) return byMachineGroups
    const q = search.toLowerCase()
    return byMachineGroups
      .map(s => ({ ...s, pod_groups: s.pod_groups.filter(g => g.pod_product_name.toLowerCase().includes(q)) }))
      .filter(s => s.pod_groups.length > 0)
  }, [byMachineGroups, search])

  // ── useMemo: Flat (none) ──────────────────────────────────────────────────
  const flatRows = useMemo<MappingRow[]>(() => {
    return [...mappings].sort((a, b) => {
      const p = a.pod_product_name.localeCompare(b.pod_product_name)
      if (p !== 0) return p
      return (a.machine_name ?? '').localeCompare(b.machine_name ?? '')
    })
  }, [mappings])

  const filteredFlatRows = useMemo(() => {
    if (!search.trim()) return flatRows
    const q = search.toLowerCase()
    return flatRows.filter(r =>
      r.pod_product_name.toLowerCase().includes(q) ||
      r.boonz_product_name.toLowerCase().includes(q)
    )
  }, [flatRows, search])

  // ── Pod products for add modal ────────────────────────────────────────────
  const filteredPodProducts = useMemo(() =>
    podProducts.filter(p => p.pod_product_name.toLowerCase().includes(addPodSearch.toLowerCase()))
  , [podProducts, addPodSearch])

  // ── Accordion handlers ────────────────────────────────────────────────────
  function toggleAccordion(podId: string, machineId: string | null) {
    const key = aKey(podId, machineId)
    if (expandedKey === key) { setExpandedKey(null); return }
    setExpandedKey(key)
    setBulkOpen(false)
    setBulkSelected(new Set())
    setBulkConfirm(false)
    setSaveError(null)
    const rows = machineId === null
      ? mappings.filter(r => r.pod_product_id === podId && r.machine_id === null)
      : mappings.filter(r => r.pod_product_id === podId && r.machine_id === machineId)
    setSplitDrafts(prev => ({
      ...prev,
      [key]: rows.map(r => ({
        key: nk(),
        mapping_id: r.mapping_id,
        original_boonz_id: r.boonz_product_id,
        boonz_product_id: r.boonz_product_id,
        split_pct: r.split_pct,
        toDelete: false,
      })),
    }))
  }

  function patchSplit(draftKey: string, splitKey: string, patch: Partial<SplitDraft>) {
    setSplitDrafts(prev => ({ ...prev, [draftKey]: prev[draftKey].map(s => s.key === splitKey ? { ...s, ...patch } : s) }))
  }

  function addSplitRow(draftKey: string) {
    const firstBoonz = boonzProducts[0]?.product_id ?? ''
    setSplitDrafts(prev => ({
      ...prev,
      [draftKey]: [...(prev[draftKey] ?? []), { key: nk(), mapping_id: null, original_boonz_id: null, boonz_product_id: firstBoonz, split_pct: 0, toDelete: false }],
    }))
  }

  function splitTotal(draftKey: string) {
    return (splitDrafts[draftKey] ?? []).filter(s => !s.toDelete).reduce((sum, s) => sum + (s.split_pct || 0), 0)
  }

  async function saveMapping(podId: string, machineId: string | null) {
    const key = aKey(podId, machineId)
    const lines = splitDrafts[key] ?? []
    const active = lines.filter(s => !s.toDelete)

    // Validation: all active lines must have a boonz product
    if (active.some(s => !s.boonz_product_id)) {
      setSaveError('All rows must have a boonz product selected')
      return
    }

    setSaving(true)
    setSaveError(null)
    const supabase = createClient()

    try {
      for (const line of lines) {
        if (line.toDelete) {
          // Case A: marked for deletion
          if (line.mapping_id) {
            const { error } = await supabase.from('product_mapping').delete().eq('mapping_id', line.mapping_id)
            if (error) { console.error('[ProductMapping] delete error:', error.message); throw error }
          }
        } else if (line.mapping_id && line.boonz_product_id !== line.original_boonz_id) {
          // Case C: boonz product changed — boonz_product_id is part of the unique key,
          // so we must DELETE the old row and INSERT a new one
          const { error: delErr } = await supabase.from('product_mapping').delete().eq('mapping_id', line.mapping_id)
          if (delErr) { console.error('[ProductMapping] case-C delete error:', delErr.message); throw delErr }
          const { error: insErr } = await supabase.from('product_mapping').insert({
            pod_product_id: podId,
            boonz_product_id: line.boonz_product_id,
            machine_id: machineId,
            split_pct: line.split_pct,
            status: 'Active',
          })
          if (insErr) { console.error('[ProductMapping] case-C insert error:', insErr.message); throw insErr }
        } else if (line.mapping_id) {
          // Case B: existing row, boonz product unchanged — update split_pct only
          const { error } = await supabase.from('product_mapping').update({ split_pct: line.split_pct }).eq('mapping_id', line.mapping_id)
          if (error) { console.error('[ProductMapping] update error:', error.message); throw error }
        } else {
          // Case D: brand new row
          const { error } = await supabase.from('product_mapping').upsert(
            { pod_product_id: podId, boonz_product_id: line.boonz_product_id, machine_id: machineId, split_pct: line.split_pct, status: 'Active' },
            { onConflict: 'pod_product_id,boonz_product_id,machine_id' }
          )
          if (error) { console.error('[ProductMapping] upsert error:', error.message); throw error }
        }
      }

      await loadMappings()
      setExpandedKey(null)
    } catch (err: unknown) {
      const msg = err instanceof Error ? err.message : (err as { message?: string })?.message ?? 'Save failed'
      setSaveError(msg)
    } finally {
      setSaving(false)
    }
  }

  async function applyBulk(podId: string, machineId: string | null) {
    const key = aKey(podId, machineId)
    const active = (splitDrafts[key] ?? []).filter(s => !s.toDelete)
    setBulkSaving(true)
    const supabase = createClient()
    for (const mid of bulkSelected) {
      await supabase.from('product_mapping').delete().eq('pod_product_id', podId).eq('machine_id', mid)
      if (active.length > 0) {
        await supabase.from('product_mapping').insert(
          active.map(s => ({ pod_product_id: podId, boonz_product_id: s.boonz_product_id, machine_id: mid, split_pct: s.split_pct, status: 'Active' }))
        )
      }
    }
    setBulkSaving(false)
    setBulkConfirm(false)
    setBulkOpen(false)
    setBulkSelected(new Set())
  }

  async function handleAddCreate() {
    if (!addPodId) { setAddError('Select a pod product'); return }
    if (addSplits.length === 0) { setAddError('Add at least one split row'); return }
    if (addSplits.some(s => !s.boonz_product_id)) { setAddError('All rows must have a boonz product selected'); return }
    setAdding(true)
    setAddError(null)
    const supabase = createClient()
    const machineId = addMachineId || null
    const { error } = await supabase.from('product_mapping').upsert(
      addSplits.map(s => ({ pod_product_id: addPodId, boonz_product_id: s.boonz_product_id, machine_id: machineId, split_pct: s.split_pct, status: 'Active' })),
      { onConflict: 'pod_product_id,boonz_product_id,machine_id' }
    )
    if (error) { setAddError(error.message); setAdding(false); return }
    setShowAdd(false)
    setAddPodId(''); setAddPodSearch(''); setAddMachineId('__global__'); setAddSplits([])
    setAdding(false)
    await loadMappings()
  }

  // Pre-populate splits when pod + machine are both selected in the add modal
  useEffect(() => {
    if (!showAdd || !addPodId || !addMachineId) return
    let cancelled = false
    async function prefetch() {
      setAddLoadingExisting(true)
      const supabase = createClient()
      const { data } = await supabase
        .from('product_mapping')
        .select('boonz_product_id, split_pct')
        .eq('pod_product_id', addPodId)
        .eq('machine_id', addMachineId)
        .eq('status', 'Active')
      if (cancelled) return
      if (data && data.length > 0) {
        setAddSplits(data.map(r => ({ key: nk(), boonz_product_id: r.boonz_product_id as string, split_pct: r.split_pct as number })))
        setAddIsUpdate(true)
      } else {
        setAddSplits([{ key: nk(), boonz_product_id: boonzProducts[0]?.product_id ?? '', split_pct: 100 }])
        setAddIsUpdate(false)
      }
      setAddLoadingExisting(false)
    }
    prefetch()
    return () => { cancelled = true }
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [addPodId, addMachineId, showAdd])

  const addTotal = addSplits.reduce((s, r) => s + (r.split_pct || 0), 0)

  const getMachineName = (machineId: string | null) =>
    machineId === null
      ? 'Global (all machines)'
      : (machines.find(m => m.machine_id === machineId)?.official_name ?? machineId)

  // ── Shared pod-row renderer (accordion included) ──────────────────────────
  function renderPodRow(g: PodGroup, machineId: string | null) {
    const key = aKey(g.pod_product_id, machineId)
    const isOpen = expandedKey === key
    const ok = Math.round(g.total_pct) === 100
    const drafts = splitDrafts[key] ?? []
    const activeDrafts = drafts.filter(s => !s.toDelete)
    const deletedDrafts = drafts.filter(s => s.toDelete)
    const total = splitTotal(key)
    const totalOk = Math.round(total) === 100

    return (
      <li
        key={key}
        className={`overflow-hidden rounded-xl border bg-white dark:bg-neutral-950 ${
          ok
            ? 'border-neutral-200 dark:border-neutral-800'
            : 'border-neutral-200 border-l-4 border-l-red-500 dark:border-neutral-800'
        }`}
      >
        <button
          className="flex w-full items-center justify-between px-4 py-3 text-left"
          onClick={() => toggleAccordion(g.pod_product_id, machineId)}
        >
          <p className="max-w-[55%] truncate text-sm font-semibold">{g.pod_product_name}</p>
          <div className="flex shrink-0 items-center gap-2">
            <span className="rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
              {g.split_count} product{g.split_count !== 1 ? 's' : ''}
            </span>
            <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${
              ok
                ? 'bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                : 'bg-red-100 text-red-700 dark:bg-red-900 dark:text-red-300'
            }`}>
              {ok ? '100%' : `${Math.round(g.total_pct)}% ⚠`}
            </span>
            <span className="text-xs text-neutral-400">{isOpen ? '▲' : '▼'}</span>
          </div>
        </button>

        {isOpen && (
          <div className="space-y-3 border-t border-neutral-100 px-4 pb-4 pt-3 dark:border-neutral-800">
            <p className="text-xs text-neutral-500">
              {machineId ? `Machine: ${getMachineName(machineId)}` : 'Global mapping (applies to all machines)'}
            </p>

            {/* Split rows */}
            <div className="space-y-2">
              {activeDrafts.map(s => (
                <div key={s.key} className="flex items-center gap-2">
                  <select
                    value={s.boonz_product_id}
                    onChange={e => patchSplit(key, s.key, { boonz_product_id: e.target.value })}
                    className="min-w-0 flex-1 rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-900"
                  >
                    {boonzProducts.map(b => <option key={b.product_id} value={b.product_id}>{b.boonz_product_name}</option>)}
                  </select>
                  <input
                    type="number"
                    min={0}
                    max={100}
                    step={0.1}
                    value={s.split_pct}
                    onChange={e => patchSplit(key, s.key, { split_pct: parseFloat(e.target.value) || 0 })}
                    className="w-16 shrink-0 rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-900"
                  />
                  <span className="shrink-0 text-xs text-neutral-500">%</span>
                  <button
                    onClick={() => patchSplit(key, s.key, { toDelete: true })}
                    className="shrink-0 text-sm font-bold text-red-400 hover:text-red-600"
                  >×</button>
                </div>
              ))}
              {deletedDrafts.map(s => (
                <div key={s.key} className="flex items-center gap-2 opacity-40">
                  <span className="flex-1 truncate text-xs line-through text-neutral-400">
                    {boonzProducts.find(b => b.product_id === s.boonz_product_id)?.boonz_product_name ?? s.boonz_product_id}
                  </span>
                  <button
                    onClick={() => patchSplit(key, s.key, { toDelete: false })}
                    className="shrink-0 text-xs text-blue-500 hover:text-blue-700"
                  >Undo</button>
                </div>
              ))}
            </div>

            <button
              onClick={() => addSplitRow(key)}
              className="text-xs font-medium text-blue-600 hover:text-blue-800"
            >
              + Add boonz product
            </button>

            {/* Live total */}
            <div className={`rounded-lg px-3 py-2 text-xs font-medium ${
              totalOk
                ? 'bg-green-50 text-green-700 dark:bg-green-900/30 dark:text-green-300'
                : 'bg-red-50 text-red-700 dark:bg-red-900/30 dark:text-red-300'
            }`}>
              {totalOk
                ? `${total}% of 100% — ✓`
                : total < 100
                  ? `${total}% of 100% — ${100 - total}% remaining`
                  : `${total}% of 100% — Over by ${total - 100}%`
              }
            </div>

            {saveError && (
              <div className="rounded-lg border border-red-200 bg-red-50 p-3 text-sm text-red-700 dark:border-red-800 dark:bg-red-900/20 dark:text-red-300">
                {saveError}
              </div>
            )}

            <div className="flex gap-2">
              <button
                onClick={() => saveMapping(g.pod_product_id, machineId)}
                disabled={saving}
                className="flex-1 rounded-xl bg-neutral-900 py-2.5 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
              >
                {saving ? 'Saving…' : 'Save changes'}
              </button>
              <button
                onClick={() => setExpandedKey(null)}
                className="rounded-xl border border-neutral-300 px-4 py-2 text-xs font-medium text-neutral-600 dark:border-neutral-700"
              >
                Cancel
              </button>
            </div>

            {/* Bulk apply */}
            <div className="border-t border-neutral-100 pt-3 dark:border-neutral-800">
              <button
                onClick={() => { setBulkOpen(!bulkOpen); setBulkConfirm(false) }}
                className="text-xs font-medium text-neutral-500 hover:text-neutral-700"
              >
                {bulkOpen ? '▲' : '▼'} Apply to other machines
              </button>
              {bulkOpen && (
                <div className="mt-2 space-y-2">
                  <p className="text-xs text-neutral-400">Select machines to copy these splits to (replaces existing):</p>
                  {machines
                    .filter(m => m.machine_id !== machineId)
                    .map(m => (
                      <label key={m.machine_id} className="flex items-center gap-2 text-xs">
                        <input
                          type="checkbox"
                          checked={bulkSelected.has(m.machine_id)}
                          onChange={e => {
                            const next = new Set(bulkSelected)
                            e.target.checked ? next.add(m.machine_id) : next.delete(m.machine_id)
                            setBulkSelected(next)
                          }}
                        />
                        {m.official_name}
                      </label>
                    ))
                  }
                  {bulkSelected.size > 0 && !bulkConfirm && (
                    <button
                      onClick={() => setBulkConfirm(true)}
                      className="rounded-lg bg-amber-600 px-4 py-2 text-xs font-semibold text-white hover:bg-amber-700"
                    >
                      Apply to {bulkSelected.size} machine{bulkSelected.size !== 1 ? 's' : ''}
                    </button>
                  )}
                  {bulkConfirm && (
                    <div className="rounded-lg border border-amber-300 bg-amber-50 p-3 dark:border-amber-700 dark:bg-amber-900/20">
                      <p className="text-xs font-medium text-amber-800 dark:text-amber-300">
                        Apply these splits to {bulkSelected.size} machine{bulkSelected.size !== 1 ? 's' : ''}? This will replace their existing mappings.
                      </p>
                      <div className="mt-2 flex gap-2">
                        <button
                          onClick={() => applyBulk(g.pod_product_id, machineId)}
                          disabled={bulkSaving}
                          className="rounded-lg bg-amber-600 px-3 py-1.5 text-xs font-semibold text-white disabled:opacity-50"
                        >
                          {bulkSaving ? 'Applying…' : 'Confirm'}
                        </button>
                        <button
                          onClick={() => setBulkConfirm(false)}
                          className="text-xs text-neutral-500 hover:text-neutral-700"
                        >Cancel</button>
                      </div>
                    </div>
                  )}
                </div>
              )}
            </div>
          </div>
        )}
      </li>
    )
  }

  // ── Loading state ─────────────────────────────────────────────────────────
  if (loadingRef) {
    return (
      <>
        <FieldHeader title="Product Mapping" />
        <div className="flex items-center justify-center p-12 text-sm text-neutral-400">Loading…</div>
      </>
    )
  }

  // ── Render ────────────────────────────────────────────────────────────────
  return (
    <div className="pb-24">
      <FieldHeader
        title="Product Mapping"
        rightAction={
          <button
            onClick={() => {
              setShowAdd(true)
              setAddPodId('')
              setAddPodSearch('')
              setAddMachineId(selectedMachineId ?? machines[0]?.machine_id ?? '')
              setAddSplits([])
              setAddIsUpdate(false)
              setAddError(null)
            }}
            className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700"
          >
            + New mapping
          </button>
        }
      />

      {/* Controls: machine selector + group-by pills */}
      <div className="sticky top-0 z-10 space-y-2 border-b border-neutral-200 bg-white px-4 py-3 dark:border-neutral-800 dark:bg-neutral-950">
        {/* Machine selector — hidden when groupBy = 'machine' */}
        {groupBy !== 'machine' && (
          <select
            value={selectedMachineId ?? ''}
            onChange={e => setSelectedMachineId(e.target.value || null)}
            className="w-full rounded-lg border border-neutral-300 bg-white px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-900"
          >
            {machines.map(m => <option key={m.machine_id} value={m.machine_id}>{m.official_name}</option>)}
          </select>
        )}

        {/* Group-by pills */}
        <div className="flex gap-2">
          {(['product', 'machine', 'none'] as GroupBy[]).map(g => (
            <button
              key={g}
              onClick={() => { setGroupBy(g); setSearch(''); setExpandedKey(null) }}
              className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                groupBy === g
                  ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                  : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400'
              }`}
            >
              {g === 'product' ? 'By product' : g === 'machine' ? 'By machine' : 'None (flat)'}
            </button>
          ))}
        </div>
      </div>

      {/* Search */}
      <div className="px-4 py-3">
        <input
          type="text"
          value={search}
          onChange={e => setSearch(e.target.value)}
          placeholder={groupBy === 'none' ? 'Search pod or boonz product…' : 'Search pod product…'}
          className="w-full rounded-lg border border-neutral-200 bg-white px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900"
        />
      </div>

      {loadingMaps ? (
        <div className="flex items-center justify-center p-8 text-sm text-neutral-400">Loading mappings…</div>
      ) : (
        <>
          {/* ── BY PRODUCT ───────────────────────────────────────────────── */}
          {groupBy === 'product' && (
            <>
              {selectedMachineId && (
                <p className="px-4 pb-1 text-xs text-neutral-400">
                  Showing splits for:{' '}
                  <span className="font-medium text-neutral-600 dark:text-neutral-300">
                    {getMachineName(selectedMachineId)}
                  </span>
                </p>
              )}
              <ul className="space-y-2 px-4">
                {filteredProductGroups.length === 0 && (
                  <li className="py-10 text-center text-sm text-neutral-400">
                    No mappings for {getMachineName(selectedMachineId)}
                  </li>
                )}
                {filteredProductGroups.map(g => renderPodRow(g, selectedMachineId))}
              </ul>
            </>
          )}

          {/* ── BY MACHINE ───────────────────────────────────────────────── */}
          {groupBy === 'machine' && (
            <div className="space-y-6 px-4">
              {filteredMachineSections.length === 0 && (
                <p className="py-10 text-center text-sm text-neutral-400">No mappings found</p>
              )}
              {filteredMachineSections.map(section => (
                <div key={section.machine_id ?? '__global__'}>
                  {/* Section header */}
                  <div className="mb-2 flex items-center gap-3">
                    <div className="h-px flex-1 bg-neutral-200 dark:bg-neutral-800" />
                    <span className="shrink-0 text-xs font-semibold uppercase tracking-wide text-neutral-500">
                      {section.machine_name}
                    </span>
                    <span className="shrink-0 rounded-full bg-neutral-100 px-2 py-0.5 text-xs text-neutral-500 dark:bg-neutral-800">
                      {section.pod_groups.length} product{section.pod_groups.length !== 1 ? 's' : ''}
                    </span>
                    <div className="h-px flex-1 bg-neutral-200 dark:bg-neutral-800" />
                  </div>
                  <ul className="space-y-2">
                    {section.pod_groups.map(g => renderPodRow(g, section.machine_id))}
                  </ul>
                </div>
              ))}
            </div>
          )}

          {/* ── FLAT / NONE ──────────────────────────────────────────────── */}
          {groupBy === 'none' && (
            <div className="px-4">
              <p className="mb-2 text-xs text-neutral-400">{filteredFlatRows.length} rows</p>
              <div className="overflow-hidden rounded-xl border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
                {filteredFlatRows.length === 0 && (
                  <p className="py-8 text-center text-sm text-neutral-400">No rows</p>
                )}
                {filteredFlatRows.map((r, i) => (
                  <div
                    key={r.mapping_id}
                    className={`flex items-center gap-2 px-4 py-2.5 text-xs ${
                      i > 0 ? 'border-t border-neutral-100 dark:border-neutral-800' : ''
                    }`}
                  >
                    <div className="min-w-0 flex-1">
                      <p className="truncate font-medium">{r.pod_product_name}</p>
                      <p className="truncate text-neutral-500">→ {r.boonz_product_name}</p>
                    </div>
                    <span className="shrink-0 font-medium text-blue-600">{r.split_pct}%</span>
                    <span className="shrink-0 max-w-[100px] truncate text-neutral-400">
                      {r.machine_name ?? 'Global'}
                    </span>
                    <span className={`shrink-0 rounded-full px-1.5 py-0.5 text-xs ${
                      r.status === 'Active'
                        ? 'bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                        : 'bg-neutral-100 text-neutral-500 dark:bg-neutral-800'
                    }`}>
                      {r.status}
                    </span>
                  </div>
                ))}
              </div>
            </div>
          )}
        </>
      )}

      {/* ── Add new mapping modal ─────────────────────────────────────────── */}
      {showAdd && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          <div className="absolute inset-0 bg-black/50" onClick={() => setShowAdd(false)} />
          <div className="relative z-10 max-h-[85vh] overflow-y-auto rounded-t-3xl bg-white px-4 pb-10 pt-5 dark:bg-neutral-900">
            <h3 className="mb-4 text-center text-base font-bold">New Mapping</h3>

            {addError && (
              <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">
                {addError}
              </div>
            )}

            <div className="space-y-3">
              {/* Step 1: Machine (required, no global option) */}
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">Machine *</label>
                <select
                  value={addMachineId}
                  onChange={e => { setAddMachineId(e.target.value); setAddPodId(''); setAddSplits([]) }}
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                >
                  {machines.map(m => <option key={m.machine_id} value={m.machine_id}>{m.official_name}</option>)}
                </select>
              </div>

              {/* Step 2: Pod product */}
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">Pod Product *</label>
                <input
                  type="text"
                  value={addPodSearch}
                  onChange={e => setAddPodSearch(e.target.value)}
                  placeholder="Search…"
                  className="mb-1 w-full rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                />
                <select
                  value={addPodId}
                  onChange={e => setAddPodId(e.target.value)}
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                >
                  <option value="">Select pod product…</option>
                  {filteredPodProducts.map(p => (
                    <option key={p.pod_product_id} value={p.pod_product_id}>{p.pod_product_name}</option>
                  ))}
                </select>
                {addLoadingExisting && (
                  <p className="mt-1 text-xs text-neutral-400">Loading existing splits…</p>
                )}
                {addIsUpdate && !addLoadingExisting && (
                  <p className="mt-1 text-xs text-amber-600">Existing splits loaded — editing will overwrite them.</p>
                )}
              </div>

              {/* Splits */}
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">Boonz Product Splits</label>
                <div className="space-y-2">
                  {addSplits.map(s => (
                    <div key={s.key} className="flex items-center gap-2">
                      <select
                        value={s.boonz_product_id}
                        onChange={e => setAddSplits(prev => prev.map(r => r.key === s.key ? { ...r, boonz_product_id: e.target.value } : r))}
                        className="min-w-0 flex-1 rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                      >
                        {boonzProducts.map(b => <option key={b.product_id} value={b.product_id}>{b.boonz_product_name}</option>)}
                      </select>
                      <input
                        type="number"
                        min={0}
                        max={100}
                        step={0.1}
                        value={s.split_pct}
                        onChange={e => setAddSplits(prev => prev.map(r => r.key === s.key ? { ...r, split_pct: parseFloat(e.target.value) || 0 } : r))}
                        className="w-16 shrink-0 rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                      />
                      <span className="shrink-0 text-xs text-neutral-500">%</span>
                      <button
                        onClick={() => setAddSplits(prev => prev.filter(r => r.key !== s.key))}
                        className="shrink-0 text-sm font-bold text-red-400 hover:text-red-600"
                      >×</button>
                    </div>
                  ))}
                </div>
                <button
                  onClick={() => setAddSplits(prev => [...prev, { key: nk(), boonz_product_id: boonzProducts[0]?.product_id ?? '', split_pct: 0 }])}
                  className="mt-2 text-xs font-medium text-blue-600 hover:text-blue-800"
                >
                  + Add row
                </button>
              </div>

              {/* Live total */}
              <div className={`rounded-lg px-3 py-2 text-xs font-medium ${
                Math.round(addTotal) === 100
                  ? 'bg-green-50 text-green-700'
                  : 'bg-amber-50 text-amber-700'
              }`}>
                {Math.round(addTotal) === 100
                  ? `${addTotal}% ✓`
                  : addTotal < 100
                    ? `${addTotal}% — ${100 - addTotal}% remaining`
                    : `${addTotal}% — over by ${addTotal - 100}%`
                }
              </div>

              <button
                onClick={handleAddCreate}
                disabled={adding || addLoadingExisting}
                className="w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
              >
                {adding ? 'Saving…' : addIsUpdate ? 'Update mapping' : 'Create mapping'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
