'use client'

export const dynamic = 'force-dynamic'

import { useEffect, useState, useCallback } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

const ADMIN_ROLES = ['operator_admin', 'superadmin', 'manager']
const STATUS_OPTIONS = ['Active', 'Inactive', 'Dormant'] as const
type MappingStatus = typeof STATUS_OPTIONS[number]

interface MappingRow {
  mapping_id: string
  pod_product_id: string
  pod_product_name: string
  boonz_product_id: string
  boonz_product_name: string
  machine_id: string | null
  machine_name: string | null
  split_pct: number
  is_global_default: boolean
  status: string
  avg_cost: number | null
}

interface MappingDraft {
  boonz_product_id: string
  machine_id: string | null
  split_pct: number
  status: string
  avg_cost: string
}

interface PodProduct { pod_product_id: string; pod_product_name: string }
interface BoonzProduct { product_id: string; boonz_product_name: string }
interface Machine { machine_id: string; official_name: string }

type FilterTab = 'all' | 'global' | 'machine' | 'active' | 'inactive'

export default function ProductMappingPage() {
  const router = useRouter()
  const [rows, setRows] = useState<MappingRow[]>([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [filterTab, setFilterTab] = useState<FilterTab>('all')

  // Reference data for dropdowns
  const [podProducts, setPodProducts] = useState<PodProduct[]>([])
  const [boonzProducts, setBoonzProducts] = useState<BoonzProduct[]>([])
  const [machines, setMachines] = useState<Machine[]>([])

  // Inline edit
  const [expandedId, setExpandedId] = useState<string | null>(null)
  const [drafts, setDrafts] = useState<Record<string, MappingDraft>>({})
  const [saving, setSaving] = useState<Record<string, boolean>>({})
  const [saveMsg, setSaveMsg] = useState<Record<string, string>>({})

  // Add new
  const [showAdd, setShowAdd] = useState(false)
  const [newPodId, setNewPodId] = useState('')
  const [newBoonzId, setNewBoonzId] = useState('')
  const [newMachineId, setNewMachineId] = useState<string>('__global__')
  const [newSplitPct, setNewSplitPct] = useState('100')
  const [newStatus, setNewStatus] = useState<MappingStatus>('Active')
  const [newAvgCost, setNewAvgCost] = useState('')
  const [adding, setAdding] = useState(false)
  const [addError, setAddError] = useState<string | null>(null)

  // Dropdown search helpers
  const [boonzSearch, setBoonzSearch] = useState('')
  const [newBoonzSearch, setNewBoonzSearch] = useState('')
  const [newPodSearch, setNewPodSearch] = useState('')

  const fetchData = useCallback(async () => {
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) { router.push('/login'); return }
    const { data: profile } = await supabase.from('user_profiles').select('role').eq('id', user.id).single()
    if (!profile || !ADMIN_ROLES.includes(profile.role)) { router.push('/field'); return }

    const [
      { data: mappingData },
      { data: podData },
      { data: boonzData },
      { data: machineData },
    ] = await Promise.all([
      supabase
        .from('product_mapping')
        .select('mapping_id, pod_product_id, boonz_product_id, machine_id, split_pct, is_global_default, status, avg_cost, pod_products!inner(pod_product_name), boonz_products!inner(boonz_product_name), machines(official_name)')
        .order('pod_product_id'),
      supabase.from('pod_products').select('pod_product_id, pod_product_name').order('pod_product_name'),
      supabase.from('boonz_products').select('product_id, boonz_product_name').order('boonz_product_name'),
      supabase.from('machines').select('machine_id, official_name').eq('status', 'active').order('official_name'),
    ])

    if (mappingData) {
      const mapped: MappingRow[] = mappingData.map((r) => {
        const pp = r.pod_products as unknown as { pod_product_name: string }
        const bp = r.boonz_products as unknown as { boonz_product_name: string }
        const m = r.machines as unknown as { official_name: string } | null
        return {
          mapping_id: r.mapping_id,
          pod_product_id: r.pod_product_id,
          pod_product_name: pp.pod_product_name,
          boonz_product_id: r.boonz_product_id,
          boonz_product_name: bp.boonz_product_name,
          machine_id: r.machine_id,
          machine_name: m?.official_name ?? null,
          split_pct: r.split_pct ?? 100,
          is_global_default: !!r.is_global_default,
          status: r.status ?? 'Active',
          avg_cost: r.avg_cost,
        }
      })
      setRows(mapped)
    }
    if (podData) setPodProducts(podData)
    if (boonzData) setBoonzProducts(boonzData)
    if (machineData) setMachines(machineData)
    setLoading(false)
  }, [router])

  useEffect(() => { fetchData() }, [fetchData])

  function openEdit(row: MappingRow) {
    if (expandedId === row.mapping_id) { setExpandedId(null); return }
    setExpandedId(row.mapping_id)
    setBoonzSearch('')
    setDrafts((prev) => ({
      ...prev,
      [row.mapping_id]: {
        boonz_product_id: row.boonz_product_id,
        machine_id: row.machine_id,
        split_pct: row.split_pct,
        status: row.status,
        avg_cost: row.avg_cost?.toString() ?? '',
      },
    }))
  }

  function patchDraft(id: string, patch: Partial<MappingDraft>) {
    setDrafts((prev) => ({ ...prev, [id]: { ...prev[id], ...patch } }))
  }

  // Compute split pct sum for a pod+machine combo (excluding current mapping)
  function splitWarning(draft: MappingDraft, currentId: string, podId: string): string | null {
    const machineId = draft.machine_id
    const otherRows = rows.filter(
      (r) => r.pod_product_id === podId && r.machine_id === machineId && r.mapping_id !== currentId
    )
    const otherSum = otherRows.reduce((s, r) => s + (r.split_pct ?? 0), 0)
    const total = otherSum + (draft.split_pct ?? 0)
    if (total !== 100) return `Split %s don't add up to 100% — currently ${total}%`
    return null
  }

  async function saveEdit(id: string, podId: string) {
    const draft = drafts[id]
    if (!draft) return
    setSaving((p) => ({ ...p, [id]: true }))
    const supabase = createClient()
    const { error } = await supabase
      .from('product_mapping')
      .update({
        boonz_product_id: draft.boonz_product_id,
        machine_id: draft.machine_id,
        is_global_default: draft.machine_id === null,
        split_pct: draft.split_pct,
        status: draft.status,
        avg_cost: draft.avg_cost ? parseFloat(draft.avg_cost) : null,
      })
      .eq('mapping_id', id)

    if (error) {
      setSaveMsg((p) => ({ ...p, [id]: `Error: ${error.message}` }))
    } else {
      setSaveMsg((p) => ({ ...p, [id]: 'Saved ✓' }))
      await fetchData()
      setExpandedId(null)
      setTimeout(() => setSaveMsg((p) => ({ ...p, [id]: '' })), 2000)
    }
    setSaving((p) => ({ ...p, [id]: false }))
    void podId
  }

  async function handleAdd() {
    if (!newPodId || !newBoonzId) { setAddError('Select pod product and boonz product'); return }
    setAdding(true)
    setAddError(null)
    const supabase = createClient()
    const machineId = newMachineId === '__global__' ? null : newMachineId
    const { error } = await supabase.from('product_mapping').insert({
      pod_product_id: newPodId,
      boonz_product_id: newBoonzId,
      machine_id: machineId,
      is_global_default: machineId === null,
      split_pct: parseFloat(newSplitPct) || 100,
      status: newStatus,
      avg_cost: newAvgCost ? parseFloat(newAvgCost) : null,
    })
    if (error) { setAddError(error.message); setAdding(false); return }
    setShowAdd(false)
    setNewPodId(''); setNewBoonzId(''); setNewMachineId('__global__')
    setNewSplitPct('100'); setNewStatus('Active'); setNewAvgCost('')
    setNewBoonzSearch(''); setNewPodSearch('')
    await fetchData()
    setAdding(false)
  }

  const FILTER_TABS: { label: string; value: FilterTab }[] = [
    { label: 'All', value: 'all' },
    { label: 'Global', value: 'global' },
    { label: 'Machine', value: 'machine' },
    { label: 'Active', value: 'active' },
    { label: 'Inactive', value: 'inactive' },
  ]

  const filtered = rows.filter((r) => {
    const q = search.toLowerCase()
    const matchSearch = !q || r.pod_product_name.toLowerCase().includes(q) || r.boonz_product_name.toLowerCase().includes(q)
    let matchFilter = true
    if (filterTab === 'global') matchFilter = r.machine_id === null
    if (filterTab === 'machine') matchFilter = r.machine_id !== null
    if (filterTab === 'active') matchFilter = r.status === 'Active'
    if (filterTab === 'inactive') matchFilter = r.status !== 'Active'
    return matchSearch && matchFilter
  })

  const filteredBoonz = boonzProducts.filter((b) => b.boonz_product_name.toLowerCase().includes(boonzSearch.toLowerCase()))
  const filteredNewBoonz = boonzProducts.filter((b) => b.boonz_product_name.toLowerCase().includes(newBoonzSearch.toLowerCase()))
  const filteredNewPod = podProducts.filter((p) => p.pod_product_name.toLowerCase().includes(newPodSearch.toLowerCase()))

  if (loading) {
    return (
      <>
        <FieldHeader title="Product Mapping" />
        <div className="flex items-center justify-center p-8"><p className="text-neutral-500">Loading…</p></div>
      </>
    )
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Product Mapping"
        rightAction={
          <button
            onClick={() => setShowAdd(true)}
            className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700"
          >
            + Add
          </button>
        }
      />

      <div className="px-4 py-4">
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search pod or boonz product…"
          className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
        />

        {/* Filter tabs */}
        <div className="mb-3 flex gap-2 overflow-x-auto pb-1">
          {FILTER_TABS.map((t) => (
            <button
              key={t.value}
              onClick={() => setFilterTab(t.value)}
              className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                filterTab === t.value
                  ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                  : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400'
              }`}
            >
              {t.label}
            </button>
          ))}
        </div>

        <p className="mb-3 text-xs text-neutral-500">{filtered.length} mappings</p>

        <ul className="space-y-2">
          {filtered.map((row) => {
            const isExpanded = expandedId === row.mapping_id
            const draft = drafts[row.mapping_id]
            const warning = draft ? splitWarning(draft, row.mapping_id, row.pod_product_id) : null

            return (
              <li key={row.mapping_id} className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
                {/* Row header */}
                <div className="cursor-pointer p-3" onClick={() => openEdit(row)}>
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-medium truncate">{row.pod_product_name}</p>
                      <p className="text-xs text-neutral-500 truncate">→ {row.boonz_product_name}</p>
                      <div className="mt-1 flex flex-wrap gap-1">
                        <span className="rounded-full bg-blue-50 px-2 py-0.5 text-xs text-blue-700">
                          {row.split_pct}%
                        </span>
                        <span className="rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-400">
                          {row.machine_name ?? 'Global'}
                        </span>
                        <span className={`rounded-full px-2 py-0.5 text-xs ${
                          row.status === 'Active' ? 'bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                          : 'bg-neutral-100 text-neutral-500 dark:bg-neutral-800'
                        }`}>{row.status}</span>
                      </div>
                    </div>
                    <div className="text-right shrink-0">
                      {row.avg_cost != null && (
                        <p className="text-xs text-neutral-500">{row.avg_cost.toFixed(2)} AED</p>
                      )}
                      <span className="text-xs text-neutral-400">{isExpanded ? '▲' : '▼'}</span>
                    </div>
                  </div>
                </div>

                {/* Expanded edit */}
                {isExpanded && draft && (
                  <div className="border-t border-neutral-100 px-3 pb-4 pt-3 dark:border-neutral-800 space-y-3">
                    {warning && (
                      <div className="rounded-lg bg-amber-50 px-3 py-2 text-xs text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                        ⚠️ {warning}
                      </div>
                    )}

                    <div>
                      <label className="mb-1 block text-xs font-medium text-neutral-500">Boonz Product</label>
                      <input
                        type="text"
                        value={boonzSearch}
                        onChange={(e) => setBoonzSearch(e.target.value)}
                        placeholder="Search…"
                        className="mb-1 w-full rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-600 dark:bg-neutral-900"
                      />
                      <select
                        value={draft.boonz_product_id}
                        onChange={(e) => patchDraft(row.mapping_id, { boonz_product_id: e.target.value })}
                        className="w-full rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-900"
                      >
                        {filteredBoonz.map((b) => (
                          <option key={b.product_id} value={b.product_id}>{b.boonz_product_name}</option>
                        ))}
                      </select>
                    </div>

                    <div>
                      <label className="mb-1 block text-xs font-medium text-neutral-500">Machine</label>
                      <select
                        value={draft.machine_id ?? '__global__'}
                        onChange={(e) => patchDraft(row.mapping_id, { machine_id: e.target.value === '__global__' ? null : e.target.value })}
                        className="w-full rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-900"
                      >
                        <option value="__global__">Global (all machines)</option>
                        {machines.map((m) => (
                          <option key={m.machine_id} value={m.machine_id}>{m.official_name}</option>
                        ))}
                      </select>
                    </div>

                    <div className="grid grid-cols-2 gap-2">
                      <div>
                        <label className="mb-1 block text-xs font-medium text-neutral-500">Split %</label>
                        <input
                          type="number"
                          min={0}
                          max={100}
                          value={draft.split_pct}
                          onChange={(e) => patchDraft(row.mapping_id, { split_pct: parseFloat(e.target.value) || 0 })}
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                        />
                      </div>
                      <div>
                        <label className="mb-1 block text-xs font-medium text-neutral-500">Avg Cost (AED)</label>
                        <input
                          type="number"
                          step="0.01"
                          value={draft.avg_cost}
                          onChange={(e) => patchDraft(row.mapping_id, { avg_cost: e.target.value })}
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                        />
                      </div>
                    </div>

                    <div>
                      <label className="mb-1 block text-xs font-medium text-neutral-500">Status</label>
                      <div className="flex gap-2">
                        {STATUS_OPTIONS.map((s) => (
                          <button
                            key={s}
                            onClick={() => patchDraft(row.mapping_id, { status: s })}
                            className={`rounded-full px-3 py-1 text-xs font-medium transition-colors ${
                              draft.status === s
                                ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                                : 'bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400'
                            }`}
                          >
                            {s}
                          </button>
                        ))}
                      </div>
                    </div>

                    {saveMsg[row.mapping_id] && (
                      <p className={`text-xs font-medium ${saveMsg[row.mapping_id].startsWith('Error') ? 'text-red-600' : 'text-green-600'}`}>
                        {saveMsg[row.mapping_id]}
                      </p>
                    )}

                    <div className="flex gap-2">
                      <button
                        onClick={() => saveEdit(row.mapping_id, row.pod_product_id)}
                        disabled={saving[row.mapping_id]}
                        className="flex-1 rounded-lg bg-neutral-900 py-2 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
                      >
                        {saving[row.mapping_id] ? 'Saving…' : 'Save'}
                      </button>
                      <button
                        onClick={() => setExpandedId(null)}
                        className="rounded-lg border border-neutral-300 px-4 py-2 text-xs font-medium text-neutral-600"
                      >
                        Cancel
                      </button>
                    </div>
                  </div>
                )}
              </li>
            )
          })}
        </ul>
      </div>

      {/* Add new bottom sheet */}
      {showAdd && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          <div className="absolute inset-0 bg-black/50" onClick={() => setShowAdd(false)} />
          <div className="relative z-10 max-h-[85vh] overflow-y-auto rounded-t-3xl bg-white px-4 pb-10 pt-5 dark:bg-neutral-900">
            <h3 className="mb-4 text-center text-base font-bold">Add Mapping</h3>

            {addError && (
              <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">{addError}</div>
            )}

            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">Pod Product</label>
                <input
                  type="text"
                  value={newPodSearch}
                  onChange={(e) => setNewPodSearch(e.target.value)}
                  placeholder="Search pod product…"
                  className="mb-1 w-full rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                />
                <select
                  value={newPodId}
                  onChange={(e) => setNewPodId(e.target.value)}
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                >
                  <option value="">Select pod product…</option>
                  {filteredNewPod.map((p) => (
                    <option key={p.pod_product_id} value={p.pod_product_id}>{p.pod_product_name}</option>
                  ))}
                </select>
              </div>

              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">Boonz Product</label>
                <input
                  type="text"
                  value={newBoonzSearch}
                  onChange={(e) => setNewBoonzSearch(e.target.value)}
                  placeholder="Search boonz product…"
                  className="mb-1 w-full rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                />
                <select
                  value={newBoonzId}
                  onChange={(e) => setNewBoonzId(e.target.value)}
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                >
                  <option value="">Select boonz product…</option>
                  {filteredNewBoonz.map((b) => (
                    <option key={b.product_id} value={b.product_id}>{b.boonz_product_name}</option>
                  ))}
                </select>
              </div>

              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">Machine</label>
                <select
                  value={newMachineId}
                  onChange={(e) => setNewMachineId(e.target.value)}
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-xs dark:border-neutral-600 dark:bg-neutral-800"
                >
                  <option value="__global__">Global (all machines)</option>
                  {machines.map((m) => (
                    <option key={m.machine_id} value={m.machine_id}>{m.official_name}</option>
                  ))}
                </select>
              </div>

              <div className="grid grid-cols-2 gap-2">
                <div>
                  <label className="mb-1 block text-xs font-medium text-neutral-500">Split %</label>
                  <input
                    type="number"
                    min={0}
                    max={100}
                    value={newSplitPct}
                    onChange={(e) => setNewSplitPct(e.target.value)}
                    className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-800"
                  />
                </div>
                <div>
                  <label className="mb-1 block text-xs font-medium text-neutral-500">Avg Cost (AED)</label>
                  <input
                    type="number"
                    step="0.01"
                    value={newAvgCost}
                    onChange={(e) => setNewAvgCost(e.target.value)}
                    placeholder="Optional"
                    className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-800"
                  />
                </div>
              </div>

              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">Status</label>
                <div className="flex gap-2">
                  {STATUS_OPTIONS.map((s) => (
                    <button
                      key={s}
                      onClick={() => setNewStatus(s)}
                      className={`rounded-full px-3 py-1 text-xs font-medium ${
                        newStatus === s
                          ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                          : 'bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400'
                      }`}
                    >
                      {s}
                    </button>
                  ))}
                </div>
              </div>

              <button
                onClick={handleAdd}
                disabled={adding}
                className="w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50"
              >
                {adding ? 'Creating…' : 'Create Mapping'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
