'use client'

export const dynamic = 'force-dynamic'

import { useEffect, useState, useCallback, useMemo } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

const ADMIN_ROLES = ['operator_admin', 'superadmin', 'manager']

interface PodProduct {
  pod_product_id: string
  custom_code: string | null
  pod_product_name: string
  product_category: string | null
  barcode: string | null
  machine_type: string | null
  measurement_method: string | null
  weight_g: number | null
  purchasing_cost: number | null
  recommended_selling_price: number | null
  supplier_id: string | null
  supplier_name: string | null
}

interface PodDraft {
  pod_product_name: string
  custom_code: string
  product_category: string
  barcode: string
  machine_type: string
  measurement_method: string
  weight_g: string
  purchasing_cost: string
  recommended_selling_price: string
  supplier_id: string
}

interface Supplier { supplier_id: string; supplier_name: string }

function emptyDraft(): PodDraft {
  return {
    pod_product_name: '', custom_code: '', product_category: '', barcode: '',
    machine_type: '', measurement_method: '', weight_g: '', purchasing_cost: '',
    recommended_selling_price: '', supplier_id: '',
  }
}

function rowToDraft(r: PodProduct): PodDraft {
  return {
    pod_product_name: r.pod_product_name,
    custom_code: r.custom_code ?? '',
    product_category: r.product_category ?? '',
    barcode: r.barcode ?? '',
    machine_type: r.machine_type ?? '',
    measurement_method: r.measurement_method ?? '',
    weight_g: r.weight_g?.toString() ?? '',
    purchasing_cost: r.purchasing_cost?.toString() ?? '',
    recommended_selling_price: r.recommended_selling_price?.toString() ?? '',
    supplier_id: r.supplier_id ?? '',
  }
}

function draftToPayload(d: PodDraft) {
  return {
    pod_product_name: d.pod_product_name.trim(),
    custom_code: d.custom_code.trim() || null,
    product_category: d.product_category.trim() || null,
    barcode: d.barcode.trim() || null,
    machine_type: d.machine_type.trim() || null,
    measurement_method: d.measurement_method.trim() || null,
    weight_g: d.weight_g ? parseFloat(d.weight_g) : null,
    purchasing_cost: d.purchasing_cost ? parseFloat(d.purchasing_cost) : null,
    recommended_selling_price: d.recommended_selling_price ? parseFloat(d.recommended_selling_price) : null,
    supplier_id: d.supplier_id || null,
    updated_at: new Date().toISOString(),
  }
}

function PodForm({ draft, onChange, categories, suppliers }: {
  draft: PodDraft
  onChange: (patch: Partial<PodDraft>) => void
  categories: string[]
  suppliers: Supplier[]
}) {
  return (
    <div className="space-y-3">
      <div>
        <label className="mb-1 block text-xs font-medium text-neutral-500">Product Name *</label>
        <input type="text" value={draft.pod_product_name} onChange={(e) => onChange({ pod_product_name: e.target.value })}
          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">Custom Code</label>
          <input type="text" value={draft.custom_code} onChange={(e) => onChange({ custom_code: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">Barcode</label>
          <input type="text" value={draft.barcode} onChange={(e) => onChange({ barcode: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">Category</label>
          <input type="text" list="pod-categories" value={draft.product_category} onChange={(e) => onChange({ product_category: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
          <datalist id="pod-categories">{categories.map((c) => <option key={c} value={c} />)}</datalist>
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">Machine Type</label>
          <input type="text" value={draft.machine_type} onChange={(e) => onChange({ machine_type: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">Weight (g)</label>
          <input type="number" value={draft.weight_g} onChange={(e) => onChange({ weight_g: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">Measure Method</label>
          <input type="text" value={draft.measurement_method} onChange={(e) => onChange({ measurement_method: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
        </div>
      </div>
      <div className="grid grid-cols-2 gap-2">
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">Purchasing Cost (AED)</label>
          <input type="number" step="0.01" value={draft.purchasing_cost} onChange={(e) => onChange({ purchasing_cost: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
        </div>
        <div>
          <label className="mb-1 block text-xs font-medium text-neutral-500">Selling Price (AED)</label>
          <input type="number" step="0.01" value={draft.recommended_selling_price} onChange={(e) => onChange({ recommended_selling_price: e.target.value })}
            className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900" />
        </div>
      </div>
      <div>
        <label className="mb-1 block text-xs font-medium text-neutral-500">Supplier</label>
        <select value={draft.supplier_id} onChange={(e) => onChange({ supplier_id: e.target.value })}
          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900">
          <option value="">No supplier</option>
          {suppliers.map((s) => <option key={s.supplier_id} value={s.supplier_id}>{s.supplier_name}</option>)}
        </select>
      </div>
    </div>
  )
}

export default function PodProductsPage() {
  const router = useRouter()
  const [rows, setRows] = useState<PodProduct[]>([])
  const [suppliers, setSuppliers] = useState<Supplier[]>([])
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')

  const [expandedId, setExpandedId] = useState<string | null>(null)
  const [drafts, setDrafts] = useState<Record<string, PodDraft>>({})
  const [saving, setSaving] = useState<Record<string, boolean>>({})
  const [saveMsg, setSaveMsg] = useState<Record<string, string>>({})

  const [showAdd, setShowAdd] = useState(false)
  const [newDraft, setNewDraft] = useState<PodDraft>(emptyDraft())
  const [adding, setAdding] = useState(false)
  const [addError, setAddError] = useState<string | null>(null)

  const fetchData = useCallback(async () => {
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) { router.push('/login'); return }
    const { data: profile } = await supabase.from('user_profiles').select('role').eq('id', user.id).single()
    if (!profile || !ADMIN_ROLES.includes(profile.role)) { router.push('/field'); return }

    const [{ data: podData }, { data: supplierData }] = await Promise.all([
      supabase
        .from('pod_products')
        .select('pod_product_id, custom_code, pod_product_name, product_category, barcode, machine_type, measurement_method, weight_g, purchasing_cost, recommended_selling_price, supplier_id, suppliers(supplier_name)')
        .order('pod_product_name'),
      supabase.from('suppliers').select('supplier_id, supplier_name').eq('status', 'Active').order('supplier_name'),
    ])

    if (podData) {
      setRows(podData.map((r) => {
        const s = r.suppliers as unknown as { supplier_name: string } | null
        return { ...r, supplier_name: s?.supplier_name ?? null } as PodProduct
      }))
    }
    if (supplierData) setSuppliers(supplierData)
    setLoading(false)
  }, [router])

  useEffect(() => { fetchData() }, [fetchData])

  const categories = useMemo(() => [...new Set(rows.map(r => r.product_category).filter(Boolean))].sort() as string[], [rows])

  const filtered = useMemo(() => {
    if (!search.trim()) return rows
    const q = search.toLowerCase()
    return rows.filter(r => r.pod_product_name.toLowerCase().includes(q) || (r.custom_code ?? '').toLowerCase().includes(q))
  }, [rows, search])

  function openEdit(row: PodProduct) {
    if (expandedId === row.pod_product_id) { setExpandedId(null); return }
    setExpandedId(row.pod_product_id)
    setDrafts((p) => ({ ...p, [row.pod_product_id]: rowToDraft(row) }))
  }

  async function saveEdit(id: string) {
    const draft = drafts[id]
    if (!draft || !draft.pod_product_name.trim()) return
    setSaving((p) => ({ ...p, [id]: true }))
    const supabase = createClient()
    const { error } = await supabase.from('pod_products').update(draftToPayload(draft)).eq('pod_product_id', id)
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
    if (!newDraft.pod_product_name.trim()) { setAddError('Product name required'); return }
    setAdding(true); setAddError(null)
    const supabase = createClient()
    const { error } = await supabase.from('pod_products').insert(draftToPayload(newDraft))
    if (error) { setAddError(error.message); setAdding(false); return }
    setShowAdd(false); setNewDraft(emptyDraft())
    await fetchData(); setAdding(false)
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Pod Products" />
        <div className="flex items-center justify-center p-8"><p className="text-neutral-500">Loading…</p></div>
      </>
    )
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Pod Products"
        rightAction={
          <button onClick={() => { setNewDraft(emptyDraft()); setShowAdd(true) }}
            className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700">
            + Add
          </button>
        }
      />
      <div className="px-4 py-4">
        <input type="text" value={search} onChange={(e) => setSearch(e.target.value)}
          placeholder="Search by name or code…"
          className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900" />
        <p className="mb-3 text-xs text-neutral-500">{filtered.length} products</p>

        <ul className="space-y-2">
          {filtered.map((row) => {
            const isExpanded = expandedId === row.pod_product_id
            const draft = drafts[row.pod_product_id]
            return (
              <li key={row.pod_product_id} className="rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
                <div className="cursor-pointer p-3" onClick={() => openEdit(row)}>
                  <div className="flex items-start justify-between gap-2">
                    <div className="min-w-0 flex-1">
                      <p className="text-sm font-semibold truncate">{row.pod_product_name}</p>
                      {row.custom_code && <p className="text-xs text-neutral-500">{row.custom_code}</p>}
                      <div className="mt-1 flex flex-wrap gap-1">
                        {row.product_category && (
                          <span className="rounded-full bg-blue-50 px-2 py-0.5 text-xs text-blue-700 dark:bg-blue-900/30 dark:text-blue-300">{row.product_category}</span>
                        )}
                        {row.machine_type && (
                          <span className="rounded-full bg-gray-100 px-2 py-0.5 text-xs text-gray-600 dark:bg-gray-800 dark:text-gray-400">{row.machine_type}</span>
                        )}
                      </div>
                    </div>
                    <div className="shrink-0 text-right">
                      {row.recommended_selling_price != null && <p className="text-xs text-neutral-500">{row.recommended_selling_price.toFixed(2)} AED</p>}
                      {row.supplier_name && <p className="text-xs text-neutral-400">{row.supplier_name}</p>}
                      <span className="text-xs text-neutral-400">{isExpanded ? '▲' : '▼'}</span>
                    </div>
                  </div>
                </div>
                {isExpanded && draft && (
                  <div className="border-t border-neutral-100 px-3 pb-4 pt-3 dark:border-neutral-800">
                    <PodForm draft={draft} onChange={(patch) => setDrafts((p) => ({ ...p, [row.pod_product_id]: { ...p[row.pod_product_id], ...patch } }))} categories={categories} suppliers={suppliers} />
                    {saveMsg[row.pod_product_id] && (
                      <p className={`mt-2 text-xs font-medium ${saveMsg[row.pod_product_id].startsWith('Error') ? 'text-red-600' : 'text-green-600'}`}>{saveMsg[row.pod_product_id]}</p>
                    )}
                    <div className="mt-3 flex gap-2">
                      <button onClick={() => saveEdit(row.pod_product_id)} disabled={saving[row.pod_product_id]}
                        className="flex-1 rounded-lg bg-neutral-900 py-2 text-xs font-semibold text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900">
                        {saving[row.pod_product_id] ? 'Saving…' : 'Save'}
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
            <h3 className="mb-4 text-center text-base font-bold">Add Pod Product</h3>
            {addError && <div className="mb-3 rounded-lg bg-red-50 px-3 py-2 text-xs text-red-700 dark:bg-red-900/30 dark:text-red-300">{addError}</div>}
            <PodForm draft={newDraft} onChange={(patch) => setNewDraft((p) => ({ ...p, ...patch }))} categories={categories} suppliers={suppliers} />
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
