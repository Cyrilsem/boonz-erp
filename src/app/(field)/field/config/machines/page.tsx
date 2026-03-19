'use client'

export const dynamic = 'force-dynamic'

import { useEffect, useState, useCallback } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

const ADMIN_ROLES = ['operator_admin', 'superadmin', 'manager']
const MACHINE_STATUS_OPTIONS = ['active', 'inactive', 'maintenance', 'decommissioned']

// ─── Machine types ─────────────────────────────────────────────────────────────

interface Machine {
  machine_id: string
  official_name: string
  pod_number: string | null
  pod_location: string | null
  pod_address: string | null
  status: string | null
  notes: string | null
}

interface MachineDraft {
  official_name: string
  pod_number: string
  pod_location: string
  pod_address: string
  status: string
  notes: string
}

function machineRowToDraft(r: Machine): MachineDraft {
  return {
    official_name: r.official_name,
    pod_number: r.pod_number ?? '',
    pod_location: r.pod_location ?? '',
    pod_address: r.pod_address ?? '',
    status: r.status ?? 'active',
    notes: r.notes ?? '',
  }
}

// ─── Alias types ──────────────────────────────────────────────────────────────

interface Alias {
  alias_id: string
  machine_id: string
  current_official: string
  original_name: string
  official_name: string
  is_active: boolean | null
}

interface AliasDraft {
  original_name: string
  official_name: string
  is_active: boolean
}

function aliasRowToDraft(r: Alias): AliasDraft {
  return {
    original_name: r.original_name,
    official_name: r.official_name,
    is_active: !!r.is_active,
  }
}

function emptyAliasDraft(): AliasDraft {
  return { original_name: '', official_name: '', is_active: true }
}

// ─── Page ─────────────────────────────────────────────────────────────────────

type TabId = 'machines' | 'aliases'

export default function MachinesPage() {
  const router = useRouter()
  const [activeTab, setActiveTab] = useState<TabId>('machines')

  // Machines tab
  const [machines, setMachines] = useState<Machine[]>([])
  const [machineSearch, setMachineSearch] = useState('')
  const [machineExpanded, setMachineExpanded] = useState<string | null>(null)
  const [machineDrafts, setMachineDrafts] = useState<Record<string, MachineDraft>>({})
  const [machineSaving, setMachineSaving] = useState<Record<string, boolean>>({})
  const [machineSaveMsg, setMachineSaveMsg] = useState<Record<string, string>>({})

  // Aliases tab
  const [aliases, setAliases] = useState<Alias[]>([])
  const [aliasSearch, setAliasSearch] = useState('')
  const [aliasExpanded, setAliasExpanded] = useState<string | null>(null)
  const [aliasDrafts, setAliasDrafts] = useState<Record<string, AliasDraft>>({})
  const [aliasSaving, setAliasSaving] = useState<Record<string, boolean>>({})
  const [aliasSaveMsg, setAliasSaveMsg] = useState<Record<string, string>>({})

  // Add alias
  const [showAddAlias, setShowAddAlias] = useState(false)
  const [newAlias, setNewAlias] = useState<AliasDraft>(emptyAliasDraft())
  const [addingAlias, setAddingAlias] = useState(false)
  const [addAliasError, setAddAliasError] = useState<string | null>(null)
  const [machineSearch2, setMachineSearch2] = useState('')

  const [loading, setLoading] = useState(true)

  const fetchData = useCallback(async () => {
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) { router.push('/login'); return }
    const { data: profile } = await supabase.from('user_profiles').select('role').eq('id', user.id).single()
    if (!profile || !ADMIN_ROLES.includes(profile.role)) { router.push('/field'); return }

    const [{ data: machineData }, { data: aliasData }] = await Promise.all([
      supabase.from('machines').select('machine_id, official_name, pod_number, pod_location, pod_address, status, notes').order('official_name'),
      supabase
        .from('machine_name_aliases')
        .select('alias_id, machine_id, original_name, official_name, is_active, machines!inner(official_name)')
        .order('official_name'),
    ])

    if (machineData) setMachines(machineData as Machine[])
    if (aliasData) {
      setAliases(aliasData.map((r) => {
        const m = r.machines as unknown as { official_name: string }
        return { ...r, current_official: m.official_name } as Alias
      }))
    }
    setLoading(false)
  }, [router])

  useEffect(() => { fetchData() }, [fetchData])

  // ── Machine edit ─────────────────────────────────────────────────────────────
  function openMachineEdit(row: Machine) {
    if (machineExpanded === row.machine_id) { setMachineExpanded(null); return }
    setMachineExpanded(row.machine_id)
    setMachineDrafts((p) => ({ ...p, [row.machine_id]: machineRowToDraft(row) }))
  }

  function patchMachine(id: string, patch: Partial<MachineDraft>) {
    setMachineDrafts((p) => ({ ...p, [id]: { ...p[id], ...patch } }))
  }

  async function saveMachine(id: string) {
    const draft = machineDrafts[id]
    if (!draft) return
    setMachineSaving((p) => ({ ...p, [id]: true }))
    const supabase = createClient()
    const { error } = await supabase.from('machines').update({
      official_name: draft.official_name.trim(),
      pod_number: draft.pod_number.trim() || null,
      pod_location: draft.pod_location.trim() || null,
      pod_address: draft.pod_address.trim() || null,
      status: draft.status,
      notes: draft.notes.trim() || null,
      updated_at: new Date().toISOString(),
    }).eq('machine_id', id)
    if (error) {
      setMachineSaveMsg((p) => ({ ...p, [id]: `Error: ${error.message}` }))
    } else {
      setMachineSaveMsg((p) => ({ ...p, [id]: 'Saved ✓' }))
      await fetchData()
      setMachineExpanded(null)
      setTimeout(() => setMachineSaveMsg((p) => ({ ...p, [id]: '' })), 2000)
    }
    setMachineSaving((p) => ({ ...p, [id]: false }))
  }

  // ── Alias edit ────────────────────────────────────────────────────────────────
  function openAliasEdit(row: Alias) {
    if (aliasExpanded === row.alias_id) { setAliasExpanded(null); return }
    setAliasExpanded(row.alias_id)
    setAliasDrafts((p) => ({ ...p, [row.alias_id]: aliasRowToDraft(row) }))
  }

  function patchAlias(id: string, patch: Partial<AliasDraft>) {
    setAliasDrafts((p) => ({ ...p, [id]: { ...p[id], ...patch } }))
  }

  async function saveAlias(id: string) {
    const draft = aliasDrafts[id]
    if (!draft) return
    setAliasSaving((p) => ({ ...p, [id]: true }))
    const supabase = createClient()
    // Resolve machine_id from official_name
    const machine = machines.find(m => m.official_name === draft.official_name)
    const { error } = await supabase.from('machine_name_aliases').update({
      original_name: draft.original_name.trim(),
      official_name: draft.official_name.trim(),
      machine_id: machine?.machine_id ?? aliases.find(a => a.alias_id === id)?.machine_id,
      is_active: draft.is_active,
    }).eq('alias_id', id)
    if (error) {
      setAliasSaveMsg((p) => ({ ...p, [id]: `Error: ${error.message}` }))
    } else {
      setAliasSaveMsg((p) => ({ ...p, [id]: 'Saved ✓' }))
      await fetchData()
      setAliasExpanded(null)
      setTimeout(() => setAliasSaveMsg((p) => ({ ...p, [id]: '' })), 2000)
    }
    setAliasSaving((p) => ({ ...p, [id]: false }))
  }

  async function handleAddAlias() {
    if (!newAlias.original_name.trim() || !newAlias.official_name.trim()) {
      setAddAliasError('Both names required'); return
    }
    const machine = machines.find(m => m.official_name === newAlias.official_name)
    if (!machine) { setAddAliasError('Machine not found — select from the list'); return }
    setAddingAlias(true); setAddAliasError(null)
    const supabase = createClient()
    const { error } = await supabase.from('machine_name_aliases').insert({
      original_name: newAlias.original_name.trim(),
      official_name: newAlias.official_name.trim(),
      machine_id: machine.machine_id,
      is_active: newAlias.is_active,
    })
    if (error) { setAddAliasError(error.message); setAddingAlias(false); return }
    setShowAddAlias(false); setNewAlias(emptyAliasDraft()); setMachineSearch2('')
    await fetchData(); setAddingAlias(false)
  }

  const filteredMachines = machines.filter(m =>
    !machineSearch || m.official_name.toLowerCase().includes(machineSearch.toLowerCase())
  )
  const filteredAliases = aliases.filter(a =>
    !aliasSearch || a.original_name.toLowerCase().includes(aliasSearch.toLowerCase()) || a.official_name.toLowerCase().includes(aliasSearch.toLowerCase())
  )
  const filteredMachines2 = machines.filter(m =>
    !machineSearch2 || m.official_name.toLowerCase().includes(machineSearch2.toLowerCase())
  )

  if (loading) {
    return (
      <>
        <FieldHeader title="Machines & Aliases" />
        <div className="flex items-center justify-center p-8"><p className="text-neutral-500">Loading…</p></div>
      </>
    )
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Machines & Aliases"
        rightAction={activeTab === 'aliases' ? (
          <button onClick={() => { setNewAlias(emptyAliasDraft()); setShowAddAlias(true) }}
            className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700">
            + Add
          </button>
        ) : undefined}
      />

      {/* Tabs */}
      <div className="flex border-b border-neutral-200 dark:border-neutral-800">
        {(['machines', 'aliases'] as TabId[]).map((tab) => (
          <button
            key={tab}
            onClick={() => setActiveTab(tab)}
            className={`flex-1 py-3 text-sm font-medium transition-colors capitalize ${
              activeTab === tab
                ? 'border-b-2 border-blue-600 text-blue-600'
                : 'text-neutral-500 hover:text-neutral-700'
            }`}
          >
            {tab}
          </button>
        ))}
      </div>

      {activeTab === 'machines' && (
        <div className="px-4 py-4">
          <input type="text" value={machineSearch} onChange={(e) => setMachineSearch(e.target.value)}
            placeholder="Search machines…"
            className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900" />
          <p className="mb-3 text-xs text-neutral-500">{filteredMachines.length} machines</p>

          <ul className="space-y-2">
            {filteredMachines.map((row) => {
              const isExpanded = machineExpanded === row.machine_id
              const draft = machineDrafts[row.machine_id]
              return (
                <li key={row.machine_id} className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
                  <div className="cursor-pointer p-3" onClick={() => openMachineEdit(row)}>
                    <div className="flex items-start justify-between gap-2">
                      <div className="min-w-0 flex-1">
                        <p className="text-sm font-semibold truncate">{row.official_name}</p>
                        {row.pod_number && <p className="text-xs text-neutral-500">#{row.pod_number}</p>}
                        {row.pod_location && <p className="text-xs text-neutral-500">{row.pod_location}</p>}
                      </div>
                      <div className="shrink-0 text-right">
                        <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${
                          row.status === 'active' ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300'
                          : 'bg-neutral-100 text-neutral-500 dark:bg-neutral-800'
                        }`}>{row.status ?? 'unknown'}</span>
                        <p className="mt-1 text-xs text-neutral-400">{isExpanded ? '▲' : '▼'}</p>
                      </div>
                    </div>
                  </div>
                  {isExpanded && draft && (
                    <div className="border-t border-neutral-100 px-3 pb-4 pt-3 dark:border-neutral-800 space-y-2">
                      <div>
                        <label className="mb-1 block text-xs font-medium text-neutral-500">Official Name</label>
                        <input type="text" value={draft.official_name} onChange={(e) => patchMachine(row.machine_id, { official_name: e.target.value })}
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
                      </div>
                      <div className="grid grid-cols-2 gap-2">
                        <div>
                          <label className="mb-1 block text-xs font-medium text-neutral-500">Pod Number</label>
                          <input type="text" value={draft.pod_number} onChange={(e) => patchMachine(row.machine_id, { pod_number: e.target.value })}
                            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
                        </div>
                        <div>
                          <label className="mb-1 block text-xs font-medium text-neutral-500">Status</label>
                          <select value={draft.status} onChange={(e) => patchMachine(row.machine_id, { status: e.target.value })}
                            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900">
                            {MACHINE_STATUS_OPTIONS.map(s => <option key={s} value={s}>{s}</option>)}
                          </select>
                        </div>
                      </div>
                      <div>
                        <label className="mb-1 block text-xs font-medium text-neutral-500">Location</label>
                        <input type="text" value={draft.pod_location} onChange={(e) => patchMachine(row.machine_id, { pod_location: e.target.value })}
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
                      </div>
                      <div>
                        <label className="mb-1 block text-xs font-medium text-neutral-500">Address</label>
                        <input type="text" value={draft.pod_address} onChange={(e) => patchMachine(row.machine_id, { pod_address: e.target.value })}
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
                      </div>
                      <div>
                        <label className="mb-1 block text-xs font-medium text-neutral-500">Notes</label>
                        <textarea rows={2} value={draft.notes} onChange={(e) => patchMachine(row.machine_id, { notes: e.target.value })}
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
                      </div>
                      {machineSaveMsg[row.machine_id] && (
                        <p className={`text-xs font-medium ${machineSaveMsg[row.machine_id].startsWith('Error') ? 'text-red-600' : 'text-green-600'}`}>
                          {machineSaveMsg[row.machine_id]}
                        </p>
                      )}
                      <div className="flex gap-2 pt-1">
                        <button onClick={() => saveMachine(row.machine_id)} disabled={machineSaving[row.machine_id]}
                          className="flex-1 rounded-lg bg-neutral-900 py-2 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900">
                          {machineSaving[row.machine_id] ? 'Saving…' : 'Save'}
                        </button>
                        <button onClick={() => setMachineExpanded(null)}
                          className="rounded-lg border border-neutral-300 px-4 py-2 text-xs font-medium text-neutral-600">
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
      )}

      {activeTab === 'aliases' && (
        <div className="px-4 py-4">
          <input type="text" value={aliasSearch} onChange={(e) => setAliasSearch(e.target.value)}
            placeholder="Search aliases…"
            className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900" />
          <p className="mb-3 text-xs text-neutral-500">{filteredAliases.length} aliases</p>

          <ul className="space-y-2">
            {filteredAliases.map((row) => {
              const isExpanded = aliasExpanded === row.alias_id
              const draft = aliasDrafts[row.alias_id]
              return (
                <li key={row.alias_id} className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
                  <div className="cursor-pointer p-3" onClick={() => openAliasEdit(row)}>
                    <div className="flex items-center justify-between gap-2">
                      <div className="min-w-0 flex-1">
                        <p className="text-sm font-medium truncate">{row.original_name}</p>
                        <p className="text-xs text-neutral-500 truncate">→ {row.official_name}</p>
                      </div>
                      <div className="flex items-center gap-2 shrink-0">
                        <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${
                          row.is_active ? 'bg-green-100 text-green-700 dark:bg-green-900/30 dark:text-green-300'
                          : 'bg-neutral-100 text-neutral-500 dark:bg-neutral-800'
                        }`}>{row.is_active ? 'Active' : 'Inactive'}</span>
                        <span className="text-xs text-neutral-400">{isExpanded ? '▲' : '▼'}</span>
                      </div>
                    </div>
                  </div>
                  {isExpanded && draft && (
                    <div className="border-t border-neutral-100 px-3 pb-4 pt-3 dark:border-neutral-800 space-y-2">
                      <div>
                        <label className="mb-1 block text-xs font-medium text-neutral-500">Original Name</label>
                        <input type="text" value={draft.original_name} onChange={(e) => patchAlias(row.alias_id, { original_name: e.target.value })}
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
                      </div>
                      <div>
                        <label className="mb-1 block text-xs font-medium text-neutral-500">Official Name (machine)</label>
                        <input type="text" list="alias-machines" value={draft.official_name} onChange={(e) => patchAlias(row.alias_id, { official_name: e.target.value })}
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
                        <datalist id="alias-machines">{machines.map(m => <option key={m.machine_id} value={m.official_name} />)}</datalist>
                      </div>
                      <div className="flex items-center gap-2">
                        <label className="text-xs font-medium text-neutral-500">Active</label>
                        <button onClick={() => patchAlias(row.alias_id, { is_active: !draft.is_active })}
                          className={`rounded-full px-3 py-1 text-xs font-medium ${draft.is_active ? 'bg-green-600 text-white' : 'bg-neutral-200 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-400'}`}>
                          {draft.is_active ? 'Yes' : 'No'}
                        </button>
                      </div>
                      {aliasSaveMsg[row.alias_id] && (
                        <p className={`text-xs font-medium ${aliasSaveMsg[row.alias_id].startsWith('Error') ? 'text-red-600' : 'text-green-600'}`}>{aliasSaveMsg[row.alias_id]}</p>
                      )}
                      <div className="flex gap-2 pt-1">
                        <button onClick={() => saveAlias(row.alias_id)} disabled={aliasSaving[row.alias_id]}
                          className="flex-1 rounded-lg bg-neutral-900 py-2 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900">
                          {aliasSaving[row.alias_id] ? 'Saving…' : 'Save'}
                        </button>
                        <button onClick={() => setAliasExpanded(null)}
                          className="rounded-lg border border-neutral-300 px-4 py-2 text-xs font-medium text-neutral-600">
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
      )}

      {/* Add alias bottom sheet */}
      {showAddAlias && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          <div className="absolute inset-0 bg-black/50" onClick={() => setShowAddAlias(false)} />
          <div className="relative z-10 max-h-[80vh] overflow-y-auto rounded-t-3xl bg-white px-4 pb-10 pt-5 dark:bg-neutral-900">
            <h3 className="mb-4 text-center text-base font-bold">Add Alias</h3>
            {addAliasError && <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">{addAliasError}</div>}
            <div className="space-y-3">
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">Original Name</label>
                <input type="text" value={newAlias.original_name} onChange={(e) => setNewAlias(p => ({ ...p, original_name: e.target.value }))}
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-800" />
              </div>
              <div>
                <label className="mb-1 block text-xs font-medium text-neutral-500">Machine</label>
                <input type="text" value={machineSearch2} onChange={(e) => setMachineSearch2(e.target.value)}
                  placeholder="Search machines…"
                  className="mb-1 w-full rounded border border-neutral-300 px-2 py-1 text-xs dark:border-neutral-600 dark:bg-neutral-800" />
                <select value={newAlias.official_name} onChange={(e) => setNewAlias(p => ({ ...p, official_name: e.target.value }))}
                  className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-800">
                  <option value="">Select machine…</option>
                  {filteredMachines2.map(m => <option key={m.machine_id} value={m.official_name}>{m.official_name}</option>)}
                </select>
              </div>
              <div className="flex items-center gap-2">
                <label className="text-xs font-medium text-neutral-500">Active</label>
                <button onClick={() => setNewAlias(p => ({ ...p, is_active: !p.is_active }))}
                  className={`rounded-full px-3 py-1 text-xs font-medium ${newAlias.is_active ? 'bg-green-600 text-white' : 'bg-neutral-200 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-400'}`}>
                  {newAlias.is_active ? 'Yes' : 'No'}
                </button>
              </div>
              <button onClick={handleAddAlias} disabled={addingAlias}
                className="w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50">
                {addingAlias ? 'Creating…' : 'Create Alias'}
              </button>
            </div>
          </div>
        </div>
      )}
    </div>
  )
}
