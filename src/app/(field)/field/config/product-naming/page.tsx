'use client'

export const dynamic = 'force-dynamic'

import { useEffect, useState } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '@/app/(field)/components/field-header'

const ADMIN_ROLES = ['operator_admin', 'superadmin', 'manager']

interface Convention {
  id: string
  original_name: string
  official_name: string | null
  mapped_at: string | null
}

interface ConventionDraft {
  original_name: string
  official_name: string
  mapped_at: string
}

const todayStr = () => new Date().toISOString().slice(0, 10)

export default function ProductNamingPage() {
  const router = useRouter()

  const [loading, setLoading] = useState(true)
  const [conventions, setConventions] = useState<Convention[]>([])
  const [boonzNames, setBoonzNames] = useState<string[]>([])
  const [search, setSearch] = useState('')

  const [expandedId, setExpandedId] = useState<string | null>(null)
  const [drafts, setDrafts] = useState<Record<string, ConventionDraft>>({})
  const [saving, setSaving] = useState<Record<string, boolean>>({})
  const [saveMsg, setSaveMsg] = useState<Record<string, string>>({})

  const [showAdd, setShowAdd] = useState(false)
  const [newDraft, setNewDraft] = useState<ConventionDraft>({ original_name: '', official_name: '', mapped_at: '' })
  const [adding, setAdding] = useState(false)
  const [addError, setAddError] = useState('')

  useEffect(() => {
    async function init() {
      const supabase = createClient()
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) { router.replace('/login'); return }
      const { data: profile } = await supabase
        .from('user_profiles').select('role').eq('id', user.id).single()
      if (!profile || !ADMIN_ROLES.includes(profile.role)) {
        router.replace('/field'); return
      }
      await Promise.all([load(), loadBoonzNames()])
    }
    init()
  // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [])

  async function load() {
    setLoading(true)
    const supabase = createClient()
    const { data } = await supabase
      .from('product_name_conventions')
      .select('*')
      .order('original_name')
    setConventions((data as Convention[]) ?? [])
    setLoading(false)
  }

  async function loadBoonzNames() {
    const supabase = createClient()
    const { data } = await supabase
      .from('boonz_products')
      .select('product_name')
      .order('product_name')
    setBoonzNames((data ?? []).map((r: { product_name: string }) => r.product_name))
  }

  function openRow(c: Convention) {
    if (expandedId === c.id) { setExpandedId(null); return }
    setExpandedId(c.id)
    setDrafts(prev => ({
      ...prev,
      [c.id]: {
        original_name: c.original_name ?? '',
        official_name: c.official_name ?? '',
        mapped_at: c.mapped_at ? c.mapped_at.slice(0, 10) : todayStr(),
      }
    }))
  }

  function patchDraft(id: string, patch: Partial<ConventionDraft>) {
    setDrafts(prev => ({ ...prev, [id]: { ...prev[id], ...patch } }))
  }

  async function save(id: string) {
    const draft = drafts[id]
    if (!draft) return
    if (!draft.original_name.trim()) {
      setSaveMsg(prev => ({ ...prev, [id]: 'Error: Original name is required' }))
      return
    }
    setSaving(prev => ({ ...prev, [id]: true }))
    setSaveMsg(prev => ({ ...prev, [id]: '' }))
    const supabase = createClient()
    const { error } = await supabase.from('product_name_conventions').update({
      original_name: draft.original_name.trim(),
      official_name: draft.official_name.trim() || null,
      mapped_at: draft.mapped_at || null,
    }).eq('id', id)
    setSaving(prev => ({ ...prev, [id]: false }))
    if (error) {
      setSaveMsg(prev => ({ ...prev, [id]: `Error: ${error.message}` }))
    } else {
      setSaveMsg(prev => ({ ...prev, [id]: 'Saved ✓' }))
      setConventions(prev =>
        prev.map(c => c.id === id
          ? { ...c, original_name: draft.original_name.trim(), official_name: draft.official_name.trim() || null, mapped_at: draft.mapped_at || null }
          : c
        )
      )
      setTimeout(() => setSaveMsg(prev => ({ ...prev, [id]: '' })), 2000)
    }
  }

  async function addNew() {
    if (!newDraft.original_name.trim()) { setAddError('Original name is required'); return }
    const dup = conventions.find(c => c.original_name.toLowerCase() === newDraft.original_name.trim().toLowerCase())
    if (dup) { setAddError('A convention with this original name already exists'); return }
    setAdding(true)
    setAddError('')
    const supabase = createClient()
    const { error } = await supabase.from('product_name_conventions').insert([{
      original_name: newDraft.original_name.trim(),
      official_name: newDraft.official_name.trim() || null,
      mapped_at: newDraft.mapped_at || null,
    }])
    setAdding(false)
    if (error) { setAddError(error.message); return }
    setShowAdd(false)
    setNewDraft({ original_name: '', official_name: '', mapped_at: '' })
    await load()
  }

  const filtered = conventions.filter(c => {
    if (!search.trim()) return true
    const q = search.toLowerCase()
    return (
      c.original_name.toLowerCase().includes(q) ||
      (c.official_name ?? '').toLowerCase().includes(q)
    )
  })

  const inputCls = 'w-full rounded-lg border border-neutral-200 bg-white px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-900'

  function ConventionForm({
    draft,
    onChange,
  }: {
    draft: ConventionDraft
    onChange: (patch: Partial<ConventionDraft>) => void
  }) {
    return (
      <div className="space-y-3">
        <div>
          <label className="mb-0.5 block text-xs text-neutral-500 dark:text-neutral-400">Original Name *</label>
          <input
            className={inputCls}
            value={draft.original_name}
            onChange={e => onChange({ original_name: e.target.value })}
            placeholder="As it appears on invoice / source"
          />
        </div>

        <div>
          <label className="mb-0.5 block text-xs text-neutral-500 dark:text-neutral-400">Official Name (Boonz product)</label>
          <input
            className={inputCls}
            list="boonz-names-list"
            value={draft.official_name}
            onChange={e => onChange({ official_name: e.target.value })}
            placeholder="Maps to…"
          />
          <datalist id="boonz-names-list">
            {boonzNames.map(n => <option key={n} value={n} />)}
          </datalist>
        </div>

        <div>
          <label className="mb-0.5 block text-xs text-neutral-500 dark:text-neutral-400">Mapped At</label>
          <input
            className={inputCls}
            type="date"
            value={draft.mapped_at}
            onChange={e => onChange({ mapped_at: e.target.value })}
          />
        </div>
      </div>
    )
  }

  if (loading) {
    return (
      <div className="flex min-h-screen flex-col bg-neutral-50 dark:bg-neutral-950">
        <FieldHeader title="Product Naming" />
        <div className="flex flex-1 items-center justify-center text-sm text-neutral-400">Loading…</div>
      </div>
    )
  }

  return (
    <div className="flex min-h-screen flex-col bg-neutral-50 dark:bg-neutral-950">
      <FieldHeader
        title="Product Naming"
        rightAction={
          <button
            onClick={() => { setShowAdd(true); setNewDraft({ original_name: '', official_name: '', mapped_at: todayStr() }) }}
            className="text-sm font-medium text-blue-600 dark:text-blue-400"
          >
            + Add
          </button>
        }
      />

      {/* Search */}
      <div className="px-4 py-3">
        <input
          className="w-full rounded-xl border border-neutral-200 bg-white px-3 py-2 text-sm dark:border-neutral-700 dark:bg-neutral-900"
          placeholder="Search original or official name…"
          value={search}
          onChange={e => setSearch(e.target.value)}
        />
      </div>

      <div className="flex-1 space-y-2 px-4 pb-8">
        <p className="text-xs text-neutral-400">{filtered.length} convention{filtered.length !== 1 ? 's' : ''}</p>

        {filtered.length === 0 && (
          <p className="py-8 text-center text-sm text-neutral-400">
            {search ? 'No matches' : 'No conventions yet — tap + Add to create one'}
          </p>
        )}

        {filtered.map(c => {
          const isOpen = expandedId === c.id
          const draft = drafts[c.id]

          return (
            <div
              key={c.id}
              className="overflow-hidden rounded-xl border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-900"
            >
              <button
                className="flex w-full items-center justify-between px-4 py-3 text-left"
                onClick={() => openRow(c)}
              >
                <div className="min-w-0 flex-1">
                  <p className="truncate text-sm font-medium">{c.original_name}</p>
                  <p className="truncate text-xs text-neutral-400">
                    → {c.official_name ?? 'unmapped'}
                  </p>
                </div>
                <div className="ml-3 flex shrink-0 items-center gap-2">
                  {c.mapped_at && (
                    <span className="text-xs text-neutral-300 dark:text-neutral-600">
                      {c.mapped_at.slice(0, 10)}
                    </span>
                  )}
                  <span className="text-neutral-400">{isOpen ? '▲' : '▼'}</span>
                </div>
              </button>

              {isOpen && draft && (
                <div className="border-t border-neutral-100 px-4 pb-4 pt-2 dark:border-neutral-800">
                  <ConventionForm draft={draft} onChange={patch => patchDraft(c.id, patch)} />

                  {saveMsg[c.id] && (
                    <p className={`mt-3 text-sm ${saveMsg[c.id].startsWith('Error') ? 'text-red-500' : 'text-green-600'}`}>
                      {saveMsg[c.id]}
                    </p>
                  )}

                  <button
                    disabled={saving[c.id]}
                    onClick={() => save(c.id)}
                    className="mt-3 w-full rounded-xl bg-blue-600 py-2.5 text-sm font-semibold text-white disabled:opacity-50"
                  >
                    {saving[c.id] ? 'Saving…' : 'Save Changes'}
                  </button>
                </div>
              )}
            </div>
          )
        })}
      </div>

      {/* Add bottom sheet */}
      {showAdd && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end bg-black/40">
          <div className="max-h-[85vh] overflow-y-auto rounded-t-2xl bg-white px-4 pb-8 pt-4 dark:bg-neutral-900">
            <div className="mb-4 flex items-center justify-between">
              <h2 className="text-base font-semibold">New Convention</h2>
              <button onClick={() => setShowAdd(false)} className="text-neutral-400">✕</button>
            </div>

            <ConventionForm draft={newDraft} onChange={patch => setNewDraft(prev => ({ ...prev, ...patch }))} />

            {addError && <p className="mt-3 text-sm text-red-500">{addError}</p>}

            <button
              disabled={adding}
              onClick={addNew}
              className="mt-4 w-full rounded-xl bg-blue-600 py-2.5 text-sm font-semibold text-white disabled:opacity-50"
            >
              {adding ? 'Adding…' : 'Add Convention'}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
