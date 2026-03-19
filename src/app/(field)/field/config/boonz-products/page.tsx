'use client'

export const dynamic = 'force-dynamic'

import { useEffect, useState, useCallback, useMemo } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

const ADMIN_ROLES = ['operator_admin', 'superadmin', 'manager']

interface BoonzProduct {
  product_id: string
  boonz_product_name: string
  product_brand: string | null
  product_sub_brand: string | null
  product_category: string | null
  category_group: string | null
  product_weight_g: number | null
  actual_weight_g: number | null
  description: string | null
  attr_healthy: boolean | null
  attr_drink: boolean | null
  attr_salty: boolean | null
  attr_sweet: boolean | null
  attr_30days: boolean | null
  min_cost: number | null
  max_cost: number | null
  avg_cost: number | null
  sourcing_channel: string | null
}

interface ProductDraft {
  boonz_product_name: string
  product_brand: string
  product_sub_brand: string
  product_category: string
  category_group: string
  product_weight_g: string
  actual_weight_g: string
  description: string
  attr_healthy: boolean
  attr_drink: boolean
  attr_salty: boolean
  attr_sweet: boolean
  attr_30days: boolean
  min_cost: string
  max_cost: string
  avg_cost: string
  sourcing_channel: string
}

function rowToDraft(r: BoonzProduct): ProductDraft {
  return {
    boonz_product_name: r.boonz_product_name,
    product_brand: r.product_brand ?? '',
    product_sub_brand: r.product_sub_brand ?? '',
    product_category: r.product_category ?? '',
    category_group: r.category_group ?? '',
    product_weight_g: r.product_weight_g?.toString() ?? '',
    actual_weight_g: r.actual_weight_g?.toString() ?? '',
    description: r.description ?? '',
    attr_healthy: !!r.attr_healthy,
    attr_drink: !!r.attr_drink,
    attr_salty: !!r.attr_salty,
    attr_sweet: !!r.attr_sweet,
    attr_30days: !!r.attr_30days,
    min_cost: r.min_cost?.toString() ?? '',
    max_cost: r.max_cost?.toString() ?? '',
    avg_cost: r.avg_cost?.toString() ?? '',
    sourcing_channel: r.sourcing_channel ?? '',
  }
}

function emptyDraft(): ProductDraft {
  return {
    boonz_product_name: '', product_brand: '', product_sub_brand: '',
    product_category: '', category_group: '', product_weight_g: '',
    actual_weight_g: '', description: '',
    attr_healthy: false, attr_drink: false, attr_salty: false, attr_sweet: false, attr_30days: false,
    min_cost: '', max_cost: '', avg_cost: '', sourcing_channel: '',
  }
}

type SortOption = 'name' | 'category' | 'brand'

function ToggleChip({ label, value, onChange }: { label: string; value: boolean; onChange: (v: boolean) => void }) {
  return (
    <button
      type="button"
      onClick={() => onChange(!value)}
      className={`rounded-full px-3 py-1 text-xs font-medium transition-colors ${
        value
          ? 'bg-blue-600 text-white'
          : 'bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400'
      }`}
    >
      {label}
    </button>
  )
}

function ProductForm({
  draft,
  onChange,
  categories,
  categoryGroups,
}: {
  draft: ProductDraft
  onChange: (patch: Partial<ProductDraft>) => void
  categories: string[]
  categoryGroups: string[]
}) {
  return (
    <div className="space-y-4">
      <div>
        <p className="mb-2 text-xs font-bold uppercase tracking-wide text-neutral-400">Identity</p>
        <div className="space-y-2">
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">Product Name *</label>
            <input
              type="text"
              value={draft.boonz_product_name}
              onChange={(e) => onChange({ boonz_product_name: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
            />
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-500">Brand</label>
              <input type="text" value={draft.product_brand} onChange={(e) => onChange({ product_brand: e.target.value })}
                className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-500">Sub-brand</label>
              <input type="text" value={draft.product_sub_brand} onChange={(e) => onChange({ product_sub_brand: e.target.value })}
                className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
            </div>
          </div>
          <div className="grid grid-cols-2 gap-2">
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-500">Category</label>
              <input type="text" list="bp-categories" value={draft.product_category} onChange={(e) => onChange({ product_category: e.target.value })}
                className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
              <datalist id="bp-categories">{categories.map((c) => <option key={c} value={c} />)}</datalist>
            </div>
            <div>
              <label className="mb-1 block text-xs font-medium text-neutral-500">Category Group</label>
              <input type="text" list="bp-category-groups" value={draft.category_group} onChange={(e) => onChange({ category_group: e.target.value })}
                className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
              <datalist id="bp-category-groups">{categoryGroups.map((c) => <option key={c} value={c} />)}</datalist>
            </div>
          </div>
        </div>
      </div>

      <div>
        <p className="mb-2 text-xs font-bold uppercase tracking-wide text-neutral-400">Physical</p>
        <div className="grid grid-cols-2 gap-2">
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">Weight (g)</label>
            <input type="number" value={draft.product_weight_g} onChange={(e) => onChange({ product_weight_g: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">Actual Weight (g)</label>
            <input type="number" value={draft.actual_weight_g} onChange={(e) => onChange({ actual_weight_g: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
          </div>
        </div>
        <div className="mt-2">
          <label className="mb-1 block text-xs font-medium text-neutral-500">Description</label>
          <textarea rows={2} value={draft.description} onChange={(e) => onChange({ description: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
        </div>
      </div>

      <div>
        <p className="mb-2 text-xs font-bold uppercase tracking-wide text-neutral-400">Attributes</p>
        <div className="flex flex-wrap gap-2">
          <ToggleChip label="Healthy" value={draft.attr_healthy} onChange={(v) => onChange({ attr_healthy: v })} />
          <ToggleChip label="Drink" value={draft.attr_drink} onChange={(v) => onChange({ attr_drink: v })} />
          <ToggleChip label="Salty" value={draft.attr_salty} onChange={(v) => onChange({ attr_salty: v })} />
          <ToggleChip label="Sweet" value={draft.attr_sweet} onChange={(v) => onChange({ attr_sweet: v })} />
          <ToggleChip label="30-day shelf" value={draft.attr_30days} onChange={(v) => onChange({ attr_30days: v })} />
        </div>
      </div>

      <div>
        <p className="mb-2 text-xs font-bold uppercase tracking-wide text-neutral-400">Cost</p>
        <div className="grid grid-cols-3 gap-2">
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">Min</label>
            <input type="number" step="0.01" value={draft.min_cost} onChange={(e) => onChange({ min_cost: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">Max</label>
            <input type="number" step="0.01" value={draft.max_cost} onChange={(e) => onChange({ max_cost: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
          </div>
          <div>
            <label className="mb-1 block text-xs font-medium text-neutral-500">Avg</label>
            <input type="number" step="0.01" value={draft.avg_cost} onChange={(e) => onChange({ avg_cost: e.target.value })}
              className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
          </div>
        </div>
        <div className="mt-2">
          <label className="mb-1 block text-xs font-medium text-neutral-500">Sourcing Channel</label>
          <input type="text" value={draft.sourcing_channel} onChange={(e) => onChange({ sourcing_channel: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
        </div>
      </div>
    </div>
  )
}

function draftToPayload(d: ProductDraft) {
  return {
    boonz_product_name: d.boonz_product_name.trim(),
    product_brand: d.product_brand.trim() || null,
    product_sub_brand: d.product_sub_brand.trim() || null,
    product_category: d.product_category.trim() || null,
    category_group: d.category_group.trim() || null,
    product_weight_g: d.product_weight_g ? parseFloat(d.product_weight_g) : null,
    actual_weight_g: d.actual_weight_g ? parseFloat(d.actual_weight_g) : null,
    description: d.description.trim() || null,
    attr_healthy: d.attr_healthy,
    attr_drink: d.attr_drink,
    attr_salty: d.attr_salty,
    attr_sweet: d.attr_sweet,
    attr_30days: d.attr_30days,
    min_cost: d.min_cost ? parseFloat(d.min_cost) : null,
    max_cost: d.max_cost ? parseFloat(d.max_cost) : null,
    avg_cost: d.avg_cost ? parseFloat(d.avg_cost) : null,
    sourcing_channel: d.sourcing_channel.trim() || null,
    updated_at: new Date().toISOString(),
  }
}

export default function BoonzProductsPage() {
  const router = useRouter()
  const [rows, setRows] = useState<BoonzProduct[]>([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [sortBy, setSortBy] = useState<SortOption>('name')

  const [expandedId, setExpandedId] = useState<string | null>(null)
  const [drafts, setDrafts] = useState<Record<string, ProductDraft>>({})
  const [saving, setSaving] = useState<Record<string, boolean>>({})
  const [saveMsg, setSaveMsg] = useState<Record<string, string>>({})

  const [showAdd, setShowAdd] = useState(false)
  const [newDraft, setNewDraft] = useState<ProductDraft>(emptyDraft())
  const [adding, setAdding] = useState(false)
  const [addError, setAddError] = useState<string | null>(null)

  const fetchData = useCallback(async () => {
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) { router.push('/login'); return }
    const { data: profile } = await supabase.from('user_profiles').select('role').eq('id', user.id).single()
    if (!profile || !ADMIN_ROLES.includes(profile.role)) { router.push('/field'); return }

    const { data } = await supabase.from('boonz_products').select('*').order('boonz_product_name')
    if (data) setRows(data as BoonzProduct[])
    setLoading(false)
  }, [router])

  useEffect(() => { fetchData() }, [fetchData])

  const categories = useMemo(() => [...new Set(rows.map(r => r.product_category).filter(Boolean))].sort() as string[], [rows])
  const categoryGroups = useMemo(() => [...new Set(rows.map(r => r.category_group).filter(Boolean))].sort() as string[], [rows])

  const processed = useMemo(() => {
    let r = rows
    if (search.trim()) {
      const q = search.toLowerCase()
      r = r.filter((p) => p.boonz_product_name.toLowerCase().includes(q) || (p.product_brand ?? '').toLowerCase().includes(q))
    }
    return [...r].sort((a, b) => {
      if (sortBy === 'category') return (a.product_category ?? '').localeCompare(b.product_category ?? '')
      if (sortBy === 'brand') return (a.product_brand ?? '').localeCompare(b.product_brand ?? '')
      return a.boonz_product_name.localeCompare(b.boonz_product_name)
    })
  }, [rows, search, sortBy])

  function openEdit(row: BoonzProduct) {
    if (expandedId === row.product_id) { setExpandedId(null); return }
    setExpandedId(row.product_id)
    setDrafts((p) => ({ ...p, [row.product_id]: rowToDraft(row) }))
  }

  function patchDraft(id: string, patch: Partial<ProductDraft>) {
    setDrafts((p) => ({ ...p, [id]: { ...p[id], ...patch } }))
  }

  async function saveEdit(id: string) {
    const draft = drafts[id]
    if (!draft || !draft.boonz_product_name.trim()) return
    setSaving((p) => ({ ...p, [id]: true }))
    const supabase = createClient()
    const { error } = await supabase.from('boonz_products').update(draftToPayload(draft)).eq('product_id', id)
    if (error) {
      setSaveMsg((p) => ({ ...p, [id]: `Error: ${error.message}` }))
    } else {
      setSaveMsg((p) => ({ ...p, [id]: 'Saved ✓' }))
      await fetchData()
      setExpandedId(null)
      setTimeout(() => setSaveMsg((p) => ({ ...p, [id]: '' })), 2000)
    }
    setSaving((p) => ({ ...p, [id]: false }))
  }

  async function handleAdd() {
    if (!newDraft.boonz_product_name.trim()) { setAddError('Product name is required'); return }
    const exists = rows.some(r => r.boonz_product_name.toLowerCase() === newDraft.boonz_product_name.toLowerCase())
    if (exists) { setAddError('A product with this name already exists'); return }
    setAdding(true)
    setAddError(null)
    const supabase = createClient()
    const { error } = await supabase.from('boonz_products').insert(draftToPayload(newDraft))
    if (error) { setAddError(error.message); setAdding(false); return }
    setShowAdd(false)
    setNewDraft(emptyDraft())
    await fetchData()
    setAdding(false)
  }

  const SORT_OPTIONS: { label: string; value: SortOption }[] = [
    { label: 'Name A→Z', value: 'name' },
    { label: 'Category', value: 'category' },
    { label: 'Brand', value: 'brand' },
  ]

  if (loading) {
    return (
      <>
        <FieldHeader title="Boonz Products" />
        <div className="flex items-center justify-center p-8"><p className="text-neutral-500">Loading…</p></div>
      </>
    )
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Boonz Products"
        rightAction={
          <button
            onClick={() => { setNewDraft(emptyDraft()); setShowAdd(true) }}
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
          placeholder="Search by name or brand…"
          className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
        />

        <div className="mb-3 flex items-center gap-2 text-xs text-neutral-500">
          <span>Sort:</span>
          {SORT_OPTIONS.map((s) => (
            <button key={s.value} onClick={() => setSortBy(s.value)}
              className={`rounded px-2 py-1 transition-colors ${sortBy === s.value ? 'bg-neutral-200 font-medium text-neutral-900 dark:bg-neutral-700 dark:text-neutral-100' : 'hover:bg-neutral-100 dark:hover:bg-neutral-800'}`}>
              {s.label}
            </button>
          ))}
        </div>

        <p className="mb-3 text-xs text-neutral-500">{processed.length} products</p>

        <ul className="space-y-2">
          {processed.map((row) => {
            const isExpanded = expandedId === row.product_id
            const draft = drafts[row.product_id]

            return (
              <li key={row.product_id} className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
                <div className="cursor-pointer p-3" onClick={() => openEdit(row)}>
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-semibold truncate">{row.boonz_product_name}</p>
                      {row.product_brand && <p className="text-xs text-neutral-500">{row.product_brand}</p>}
                      <div className="mt-1 flex flex-wrap gap-1">
                        {row.product_category && (
                          <span className="rounded-full bg-blue-50 px-2 py-0.5 text-xs text-blue-700 dark:bg-blue-900/30 dark:text-blue-300">{row.product_category}</span>
                        )}
                        {row.category_group && (
                          <span className="rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-400">{row.category_group}</span>
                        )}
                      </div>
                    </div>
                    <div className="shrink-0 text-right">
                      {row.avg_cost != null && <p className="text-xs text-neutral-500">{row.avg_cost.toFixed(2)} AED</p>}
                      <span className="text-xs text-neutral-400">{isExpanded ? '▲' : '▼'}</span>
                    </div>
                  </div>
                </div>

                {isExpanded && draft && (
                  <div className="border-t border-neutral-100 px-3 pb-4 pt-3 dark:border-neutral-800">
                    <ProductForm
                      draft={draft}
                      onChange={(patch) => patchDraft(row.product_id, patch)}
                      categories={categories}
                      categoryGroups={categoryGroups}
                    />
                    {saveMsg[row.product_id] && (
                      <p className={`mt-2 text-xs font-medium ${saveMsg[row.product_id].startsWith('Error') ? 'text-red-600' : 'text-green-600'}`}>
                        {saveMsg[row.product_id]}
                      </p>
                    )}
                    <div className="mt-3 flex gap-2">
                      <button onClick={() => saveEdit(row.product_id)} disabled={saving[row.product_id]}
                        className="flex-1 rounded-lg bg-neutral-900 py-2 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900">
                        {saving[row.product_id] ? 'Saving…' : 'Save'}
                      </button>
                      <button onClick={() => setExpandedId(null)}
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

      {showAdd && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          <div className="absolute inset-0 bg-black/50" onClick={() => setShowAdd(false)} />
          <div className="relative z-10 max-h-[90vh] overflow-y-auto rounded-t-3xl bg-white px-4 pb-10 pt-5 dark:bg-neutral-900">
            <h3 className="mb-4 text-center text-base font-bold">Add Boonz Product</h3>
            {addError && <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">{addError}</div>}
            <ProductForm
              draft={newDraft}
              onChange={(patch) => setNewDraft((p) => ({ ...p, ...patch }))}
              categories={categories}
              categoryGroups={categoryGroups}
            />
            <button onClick={handleAdd} disabled={adding}
              className="mt-4 w-full rounded-2xl bg-blue-600 py-3 text-sm font-semibold text-white hover:bg-blue-700 disabled:opacity-50">
              {adding ? 'Creating…' : 'Create Product'}
            </button>
          </div>
        </div>
      )}
    </div>
  )
}
