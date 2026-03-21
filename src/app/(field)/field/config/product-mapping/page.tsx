'use client'

export const dynamic = 'force-dynamic'

import { useEffect, useState, useCallback, useMemo } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

const ADMIN_ROLES = ['operator_admin', 'superadmin', 'manager']

interface Machine { machine_id: string; official_name: string }
interface BoonzProduct { product_id: string; boonz_product_name: string }
interface PodProduct { pod_product_id: string; pod_product_name: string }

interface MappingRow {
  mapping_id: string
  pod_product_id: string
  pod_product_name: string
  boonz_product_id: string
  split_pct: number
}

interface PodGroup {
  pod_product_id: string
  pod_product_name: string
  total_pct: number
  split_count: number
}

interface SplitDraft {
  key: string
  mapping_id: string | null
  boonz_product_id: string
  split_pct: number
  toDelete: boolean
}

interface RawRow {
  mapping_id: string
  pod_product_id: string
  boonz_product_id: string
  split_pct: number
  pod_products: { pod_product_name: string }
}

let _k = 0
const nk = () => `k${++_k}`

export default function ProductMappingPage() {
  const router = useRouter()

  const [authed, setAuthed] = useState(false)
  const [loadingRef, setLoadingRef] = useState(true)
  const [loadingMaps, setLoadingMaps] = useState(false)

  const [machines, setMachines] = useState<Machine[]>([])
  const [boonzProducts, setBoonzProducts] = useState<BoonzProduct[]>([])
  const [podProducts, setPodProducts] = useState<PodProduct[]>([])
  const [mappings, setMappings] = useState<MappingRow[]>([])

  const [selectedMachineId, setSelectedMachineId] = useState<string | null>(null)
  const [search, setSearch] = useState('')

  // Accordion
  const [expandedPodId, setExpandedPodId] = useState<string | null>(null)
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

  // Auth + reference data
  useEffect(() => {
    async function init() {
      const supabase = createClient()
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) { router.push('/login'); return }
      const { data: profile } = await supabase.from('user_profiles').select('role').eq('id', user.id).single()
      if (!profile || !ADMIN_ROLES.includes(profile.role)) { router.push('/field'); return }

      const [{ data: mData }, { data: bData }, { data: ppData }] = await Promise.all([
        supabase.from('machines').select('machine_id, official_name').eq('status', 'active').order('official_name'),
        supabase.from('boonz_products').select('product_id, boonz_product_name').order('boonz_product_name'),
        supabase.from('pod_products').select('pod_product_id, pod_product_name').order('pod_product_name'),
      ])
      if (mData) setMachines(mData)
      if (bData) setBoonzProducts(bData)
      if (ppData) setPodProducts(ppData)
      setLoadingRef(false)
      setAuthed(true)
    }
    init()
  }, [router])

  const loadMappings = useCallback(async () => {
    setLoadingMaps(true)
    setExpandedPodId(null)
    setSplitDrafts({})
    setSaveError(null)

    const supabase = createClient()
    const sel = 'mapping_id, pod_product_id, boonz_product_id, split_pct, pod_products!inner(pod_product_name)'

    let rawData: RawRow[] = []
    if (selectedMachineId === null) {
      const { data } = await supabase.from('product_mapping').select(sel).eq('status', 'Active').is('machine_id', null)
      rawData = (data ?? []) as unknown as RawRow[]
    } else {
      const { data } = await supabase.from('product_mapping').select(sel).eq('status', 'Active').eq('machine_id', selectedMachineId)
      rawData = (data ?? []) as unknown as RawRow[]
    }

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
        split_pct: r.split_pct ?? 0,
      })
    }
    setMappings(rows)
    setLoadingMaps(false)
  }, [selectedMachineId])

  useEffect(() => { if (authed) loadMappings() }, [authed, loadMappings])

  const podGroups = useMemo<PodGroup[]>(() => {
    const map = new Map<string, PodGroup>()
    for (const r of mappings) {
      const g = map.get(r.pod_product_id)
      if (g) { g.total_pct += r.split_pct; g.split_count++ }
      else map.set(r.pod_product_id, { pod_product_id: r.pod_product_id, pod_product_name: r.pod_product_name, total_pct: r.split_pct, split_count: 1 })
    }
    return [...map.values()].sort((a, b) => a.pod_product_name.localeCompare(b.pod_product_name))
  }, [mappings])

  const filteredGroups = useMemo(() => {
    if (!search.trim()) return podGroups
    const q = search.toLowerCase()
    return podGroups.filter(g => g.pod_product_name.toLowerCase().includes(q))
  }, [podGroups, search])

  const filteredPodProducts = useMemo(() =>
    podProducts.filter(p => p.pod_product_name.toLowerCase().includes(addPodSearch.toLowerCase()))
  , [podProducts, addPodSearch])

  function toggleAccordion(podId: string) {
    if (expandedPodId === podId) { setExpandedPodId(null); return }
    setExpandedPodId(podId)
    setBulkOpen(false)
    setBulkSelected(new Set())
    setBulkConfirm(false)
    setSaveError(null)
    const rows = mappings.filter(r => r.pod_product_id === podId)
    setSplitDrafts(prev => ({
      ...prev,
      [podId]: rows.map(r => ({ key: nk(), mapping_id: r.mapping_id, boonz_product_id: r.boonz_product_id, split_pct: r.split_pct, toDelete: false })),
    }))
  }

  function patchSplit(podId: string, key: string, patch: Partial<SplitDraft>) {
    setSplitDrafts(prev => ({ ...prev, [podId]: prev[podId].map(s => s.key === key ? { ...s, ...patch } : s) }))
  }

  function addSplitRow(podId: string) {
    const firstBoonz = boonzProducts[0]?.product_id ?? ''
    setSplitDrafts(prev => ({ ...prev, [podId]: [...(prev[podId] ?? []), { key: nk(), mapping_id: null, boonz_product_id: firstBoonz, split_pct: 0, toDelete: false }] }))
  }

  function splitTotal(podId: string) {
    return (splitDrafts[podId] ?? []).filter(s => !s.toDelete).reduce((sum, s) => sum + (s.split_pct || 0), 0)
  }

  async function saveMapping(podId: string) {
    const active = (splitDrafts[podId] ?? []).filter(s => !s.toDelete)
    if (active.some(s => !s.boonz_product_id)) { setSaveError('All rows must have a boonz product selected'); return }
    setSaving(true)
    setSaveError(null)
    const supabase = createClient()

    let delError: { message: string } | null = null
    if (selectedMachineId === null) {
      const res = await supabase.from('product_mapping').delete().eq('pod_product_id', podId).is('machine_id', null)
      delError = res.error
    } else {
      const res = await supabase.from('product_mapping').delete().eq('pod_product_id', podId).eq('machine_id', selectedMachineId)
      delError = res.error
    }
    if (delError) { setSaveError(delError.message); setSaving(false); return }

    if (active.length > 0) {
      const { error: insErr } = await supabase.from('product_mapping').insert(
        active.map(s => ({ pod_product_id: podId, boonz_product_id: s.boonz_product_id, machine_id: selectedMachineId, split_pct: s.split_pct, status: 'Active' }))
      )
      if (insErr) { setSaveError(insErr.message); setSaving(false); return }
    }

    setSaving(false)
    setExpandedPodId(null)
    await loadMappings()
  }

  async function applyBulk(podId: string) {
    const active = (splitDrafts[podId] ?? []).filter(s => !s.toDelete)
    setBulkSaving(true)
    const supabase = createClient()
    for (const machineId of bulkSelected) {
      await supabase.from('product_mapping').delete().eq('pod_product_id', podId).eq('machine_id', machineId)
      if (active.length > 0) {
        await supabase.from('product_mapping').insert(
          active.map(s => ({ pod_product_id: podId, boonz_product_id: s.boonz_product_id, machine_id: machineId, split_pct: s.split_pct, status: 'Active' }))
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
    const machineId = addMachineId === '__global__' ? null : addMachineId
    const { error } = await supabase.from('product_mapping').insert(
      addSplits.map(s => ({ pod_product_id: addPodId, boonz_product_id: s.boonz_product_id, machine_id: machineId, split_pct: s.split_pct, status: 'Active' }))
    )
    if (error) { setAddError(error.message); setAdding(false); return }
    setShowAdd(false)
    setAddPodId(''); setAddPodSearch(''); setAddMachineId('__global__'); setAddSplits([])
    setAdding(false)
    await loadMappings()
  }

  const machineName = selectedMachineId
    ? (machines.find(m => m.machine_id === selectedMachineId)?.official_name ?? '')
    : 'Global'
  const addTotal = addSplits.reduce((s, r) => s + (r.split_pct || 0), 0)

  if (loadingRef) {
    return (
      <>
        <FieldHeader title="Product Mapping" />
        <div className="flex items-center justify-center p-12 text-sm text-neutral-400">Loading…</div>
      </>
    )
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Product Mapping"
        rightAction={
          <button
            onClick={() => {
              setShowAdd(true)
              setAddSplits([{ key: nk(), boonz_product_id: boonzProducts[0]?.product_id ?? '', split_pct: 100 }])
              setAddError(null)
            }}
            className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-blue-700"
          >
            + New mapping
          </button>
        }
      />

      {/* Machine selector */}
      <div className="sticky top-0 z-10 border-b border-neutral-200 bg-white px-4 py-3 dark:border-neutral-800 dark:bg-neutral-950">
        <select
          value={selectedMachineId ?? '__global__'}
          onChange={e => setSelectedMachineId(e.target.value === '__global__' ? null : e.target.value)}
          className="w-full rounded-lg border border-neutral-300 bg-white px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-900"
        >
          <option value="__global__">Global (all machines)</option>
          {machines.map(m => <option key={m.machine_id} value={m.machine_id}>{m.official_name}</option>)}
        </select>
      </div>

      <div className="px-4 py-3">
        <input
          type="text"
          value={search}
          onChange={e => setSearch(e.target.value)}
          placeholder="Search pod product…"
          className="w-full rounded-lg border border-neutral-200 bg-white px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900"
        />
      </div>

      {loadingMaps ? (
        <div className="flex items-center justify-center p-8 text-sm text-neutral-400">Loading mappings…</div>
      ) : (
        <ul className="space-y-2 px-4">
          {filteredGroups.length === 0 && (
            <li className="py-10 text-center text-sm text-neutral-400">No mappings for {machineName}</li>
          )}
          {filteredGroups.map(g => {
            const isOpen = expandedPodId === g.pod_product_id
            const ok = Math.round(g.total_pct) === 100
            const drafts = splitDrafts[g.pod_product_id] ?? []
            const activeDrafts = drafts.filter(s => !s.toDelete)
            const deletedDrafts = drafts.filter(s => s.toDelete)
            const total = splitTotal(g.pod_product_id)
            const totalOk = Math.round(total) === 100

            return (
              <li
                key={g.pod_product_id}
                className={`overflow-hidden rounded-xl border bg-white dark:bg-neutral-950 ${
                  ok
                    ? 'border-neutral-200 dark:border-neutral-800'
                    : 'border-neutral-200 border-l-4 border-l-red-500 dark:border-neutral-800'
                }`}
              >
                {/* Row header */}
                <button
                  className="flex w-full items-center justify-between px-4 py-3 text-left"
                  onClick={() => toggleAccordion(g.pod_product_id)}
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

                {/* Accordion */}
                {isOpen && (
                  <div className="space-y-3 border-t border-neutral-100 px-4 pb-4 pt-3 dark:border-neutral-800">
                    <p className="text-xs text-neutral-500">
                      {selectedMachineId ? `Machine: ${machineName}` : 'Global mapping (applies to all machines)'}
                    </p>

                    {/* Split rows */}
                    <div className="space-y-2">
                      {activeDrafts.map(s => (
                        <div key={s.key} className="flex items-center gap-2">
                          <select
                            value={s.boonz_product_id}
                            onChange={e => patchSplit(g.pod_product_id, s.key, { boonz_product_id: e.target.value })}
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
                            onChange={e => patchSplit(g.pod_product_id, s.key, { split_pct: parseFloat(e.target.value) || 0 })}
                            className="w-16 shrink-0 rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-900"
                          />
                          <span className="shrink-0 text-xs text-neutral-500">%</span>
                          <button
                            onClick={() => patchSplit(g.pod_product_id, s.key, { toDelete: true })}
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
                            onClick={() => patchSplit(g.pod_product_id, s.key, { toDelete: false })}
                            className="shrink-0 text-xs text-blue-500 hover:text-blue-700"
                          >Undo</button>
                        </div>
                      ))}
                    </div>

                    <button
                      onClick={() => addSplitRow(g.pod_product_id)}
                      className="text-xs font-medium text-blue-600 hover:text-blue-800"
                    >
                      + Add boonz product
                    </button>

                    {/* Live total bar */}
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

                    {saveError && <p className="text-xs font-medium text-red-600">{saveError}</p>}

                    <div className="flex gap-2">
                      <button
                        onClick={() => saveMapping(g.pod_product_id)}
                        disabled={saving}
                        className="flex-1 rounded-xl bg-neutral-900 py-2.5 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
                      >
                        {saving ? 'Saving…' : 'Save changes'}
                      </button>
                      <button
                        onClick={() => setExpandedPodId(null)}
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
                            .filter(m => m.machine_id !== selectedMachineId)
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
                                  onClick={() => applyBulk(g.pod_product_id)}
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
          })}
        </ul>
      )}

      {/* Add new mapping modal */}
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
              {/* Pod product */}
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
              </div>

              {/* Machine */}
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">Machine *</label>
                <select
                  value={addMachineId}
                  onChange={e => setAddMachineId(e.target.value)}
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                >
                  <option value="__global__">Global (all machines)</option>
                  {machines.map(m => <option key={m.machine_id} value={m.machine_id}>{m.official_name}</option>)}
                </select>
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
                disabled={adding}
                className="w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
              >
                {adding ? 'Creating…' : 'Create mapping'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
