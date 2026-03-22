'use client'

import { useEffect, useState, useMemo, useCallback } from 'react'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../components/field-header'
import { getExpiryStyle } from '@/app/(field)/utils/expiry'

// ─── Data types ───────────────────────────────────────────────────────────────

interface PodRow {
  pod_inventory_id: string
  machine_id: string
  boonz_product_id: string
  current_stock: number
  expiration_date: string | null
  boonz_products: {
    boonz_product_name: string
    product_category: string | null
  } | null
  machines: {
    official_name: string
  } | null
}

interface DisplayGroup {
  key: string
  headerLabel: string
  itemCount: number   // items.length OR distinct machine count for product grouping
  countLabel: string  // "items" | "machines"
  totalUnits: number
  items: PodRow[]
}

type PodFilter = 'expired' | '3days' | '7days' | '30days' | 'all'
type GroupBy = 'machine' | 'product' | 'category' | 'none'
type EditType = 'in_stock' | 'sold' | 'damaged'
type SortField = 'expiry' | 'qty' | 'product'
type SortDir = 'asc' | 'desc'

// ─── Static config ────────────────────────────────────────────────────────────

const FILTER_OPTIONS: { label: string; value: PodFilter }[] = [
  { label: 'Expired', value: 'expired' },
  { label: '< 3 days', value: '3days' },
  { label: '< 7 days', value: '7days' },
  { label: '< 30 days', value: '30days' },
  { label: 'All stock', value: 'all' },
]

const GROUP_OPTIONS: { label: string; value: GroupBy }[] = [
  { label: 'Machine', value: 'machine' },
  { label: 'Product', value: 'product' },
  { label: 'Category', value: 'category' },
  { label: 'None', value: 'none' },
]

const DEFAULT_GROUP_BY: Record<PodFilter, GroupBy> = {
  expired: 'machine',
  '3days': 'machine',
  '7days': 'machine',
  '30days': 'category',
  all: 'machine',
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function daysUntilExpiry(date: string | null): number | null {
  if (!date) return null
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const exp = new Date(date + 'T00:00:00')
  return Math.ceil((exp.getTime() - today.getTime()) / (1000 * 60 * 60 * 24))
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return '—'
  const d = new Date(dateStr + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
}

function getGroupKey(row: PodRow, groupBy: Exclude<GroupBy, 'none'>): string {
  switch (groupBy) {
    case 'machine':   return row.machines?.official_name ?? '—'
    case 'product':   return row.boonz_products?.boonz_product_name ?? '—'
    case 'category':  return row.boonz_products?.product_category ?? 'Uncategorised'
  }
}

async function compressImage(file: File): Promise<Blob> {
  return new Promise((resolve) => {
    const img = new Image()
    const blobUrl = URL.createObjectURL(file)
    img.onload = () => {
      URL.revokeObjectURL(blobUrl)
      const maxW = 1200
      let { width, height } = img
      if (width > maxW) {
        height = Math.round((height * maxW) / width)
        width = maxW
      }
      const canvas = document.createElement('canvas')
      canvas.width = width
      canvas.height = height
      const ctx = canvas.getContext('2d')!
      ctx.drawImage(img, 0, 0, width, height)
      canvas.toBlob((blob) => resolve(blob!), 'image/jpeg', 0.7)
    }
    img.src = blobUrl
  })
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function SectionHeader({
  label,
  itemCount,
  unitCount,
  countLabel = 'items',
}: {
  label: string
  itemCount: number
  unitCount: number
  countLabel?: string
}) {
  return (
    <div className="mb-2 flex items-center gap-2">
      <p className="shrink-0 text-xs font-bold uppercase tracking-wide text-neutral-700 dark:text-neutral-300">
        {label}
      </p>
      <p className="shrink-0 text-xs text-neutral-400">
        {itemCount} {countLabel} · {unitCount} units
      </p>
      <div className="flex-1 border-t border-neutral-200 dark:border-neutral-700" />
    </div>
  )
}

interface PodRowItemProps {
  row: PodRow
  showProduct: boolean
  showMachine: boolean
  showCategory: boolean
  isPending: boolean
  onClick: () => void
}

function PodRowItem({ row, showProduct, showMachine, showCategory, isPending, onClick }: PodRowItemProps) {
  const style = getExpiryStyle(row.expiration_date)

  const line1 = showProduct
    ? (row.boonz_products?.boonz_product_name ?? '—')
    : (row.machines?.official_name ?? '—')

  const line2: string | null = showProduct
    ? showCategory
      ? (row.boonz_products?.product_category ?? 'Uncategorised')
      : showMachine
      ? (row.machines?.official_name ?? '—')
      : null
    : null

  return (
    <li
      className="cursor-pointer flex items-start rounded-lg border border-neutral-200 bg-white p-4 transition-colors active:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:active:bg-neutral-900"
      onClick={onClick}
    >
      {/* Left side */}
      <div className="min-w-0 flex-1 pr-3">
        <p className="truncate text-sm font-bold">{line1}</p>
        {line2 !== null && (
          <p className="mt-0.5 truncate text-xs text-neutral-500">{line2}</p>
        )}
        <div className="mt-1.5 flex flex-wrap items-center gap-2">
          <span className="text-xs text-neutral-400">{formatDate(row.expiration_date)}</span>
          {style.label && (
            <span className={`rounded-full ${style.badgeBg} px-3 py-1 text-sm font-semibold ${style.badgeText}`}>
              {style.label}
            </span>
          )}
          {isPending && (
            <span className="rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700 dark:bg-amber-900 dark:text-amber-300">
              Review pending
            </span>
          )}
        </div>
      </div>

      {/* Right side: qty */}
      <div className={`flex shrink-0 flex-col items-end ${style.qtyColor}`}>
        <p className="text-xl font-bold leading-none">{row.current_stock}</p>
        <p className="mt-0.5 text-xs opacity-60">units</p>
      </div>
    </li>
  )
}

// ─── Row props per groupBy ────────────────────────────────────────────────────

function rowProps(groupBy: GroupBy): Omit<PodRowItemProps, 'row' | 'isPending' | 'onClick'> {
  switch (groupBy) {
    case 'machine':   return { showProduct: true,  showMachine: false, showCategory: true  }
    case 'product':   return { showProduct: false, showMachine: true,  showCategory: false }
    case 'category':  return { showProduct: true,  showMachine: true,  showCategory: false }
    case 'none':      return { showProduct: true,  showMachine: true,  showCategory: false }
  }
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function PodInventoryPage() {
  const [rows, setRows] = useState<PodRow[]>([])
  const [loading, setLoading] = useState(true)
  const [filter, setFilter] = useState<PodFilter>('all')
  const [groupBy, setGroupBy] = useState<GroupBy>(DEFAULT_GROUP_BY['7days'])
  const [selectedMachine, setSelectedMachine] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [sortField, setSortField] = useState<SortField>('expiry')
  const [sortDir, setSortDir] = useState<SortDir>('asc')

  // Pending edits
  const [pendingEditIds, setPendingEditIds] = useState<Set<string>>(new Set())

  // Toast
  const [toast, setToast] = useState<string | null>(null)

  // Edit modal
  const [selectedRow, setSelectedRow] = useState<PodRow | null>(null)
  const [editType, setEditType] = useState<EditType | null>(null)
  const [editQty, setEditQty] = useState<number>(0)
  const [editNotes, setEditNotes] = useState('')
  const [editPhoto, setEditPhoto] = useState<File | null>(null)
  const [editPhotoUrl, setEditPhotoUrl] = useState<string | null>(null)
  const [editSubmitting, setEditSubmitting] = useState(false)
  const [editError, setEditError] = useState<string | null>(null)

  // Reset expiry filter changes
  function handleFilterChange(newFilter: PodFilter) {
    setFilter(newFilter)
    setGroupBy(DEFAULT_GROUP_BY[newFilter])
    setSelectedMachine(null)
  }

  function closeModal() {
    setSelectedRow(null)
    setEditType(null)
    setEditQty(0)
    setEditNotes('')
    if (editPhotoUrl) URL.revokeObjectURL(editPhotoUrl)
    setEditPhoto(null)
    setEditPhotoUrl(null)
    setEditSubmitting(false)
    setEditError(null)
  }

  const fetchPendingEdits = useCallback(async () => {
    const supabase = createClient()
    const { data } = await supabase
      .from('pod_inventory_edits')
      .select('pod_inventory_id')
      .eq('status', 'pending')
    if (data) {
      setPendingEditIds(new Set(data.map((r) => r.pod_inventory_id as string)))
    }
  }, [])

  const fetchData = useCallback(async () => {
    const supabase = createClient()

    const { data } = await supabase
      .from('pod_inventory')
      .select(`
        pod_inventory_id,
        machine_id,
        boonz_product_id,
        current_stock,
        expiration_date,
        status,
        boonz_products ( boonz_product_name, product_category ),
        machines ( official_name )
      `)
      .eq('status', 'Active')
      .gt('current_stock', 0)
      .order('expiration_date', { ascending: true })
      .limit(10000)

    if (data) {
      setRows(data.map((row) => ({
        pod_inventory_id: row.pod_inventory_id,
        machine_id: row.machine_id,
        boonz_product_id: row.boonz_product_id,
        current_stock: row.current_stock ?? 0,
        expiration_date: row.expiration_date,
        boonz_products: row.boonz_products as unknown as { boonz_product_name: string; product_category: string | null } | null,
        machines: row.machines as unknown as { official_name: string } | null,
      })))
    }
    setLoading(false)
  }, [])

  useEffect(() => {
    fetchData()
    fetchPendingEdits()

    const handleVisibility = () => {
      if (document.visibilityState === 'visible') fetchData()
    }
    const handleFocus = () => fetchData()

    document.addEventListener('visibilitychange', handleVisibility)
    window.addEventListener('focus', handleFocus)

    return () => {
      document.removeEventListener('visibilitychange', handleVisibility)
      window.removeEventListener('focus', handleFocus)
    }
  }, [fetchData, fetchPendingEdits])

  async function submitEdit() {
    if (!selectedRow || !editType) return
    setEditSubmitting(true)
    setEditError(null)

    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) {
      setEditError('Not authenticated')
      setEditSubmitting(false)
      return
    }

    let photoPath: string | null = null
    if (editPhoto && editType === 'damaged') {
      try {
        const compressed = await compressImage(editPhoto)
        const timestamp = Date.now()
        const path = `${selectedRow.pod_inventory_id}/${timestamp}.jpg`
        const { error: uploadError } = await supabase.storage
          .from('pod-inventory-edits')
          .upload(path, compressed, { contentType: 'image/jpeg' })
        if (uploadError) throw uploadError
        photoPath = path
      } catch {
        setEditError('Failed to upload photo. Please try again.')
        setEditSubmitting(false)
        return
      }
    }

    const { error: insertError } = await supabase
      .from('pod_inventory_edits')
      .insert({
        pod_inventory_id: selectedRow.pod_inventory_id,
        machine_id: selectedRow.machine_id,
        boonz_product_id: selectedRow.boonz_product_id,
        requested_by: user.id,
        edit_type: editType,
        quantity_update:
          editType === 'sold' || editType === 'damaged' ? editQty || null : null,
        photo_path: photoPath,
        notes: editNotes.trim() || null,
      })

    if (insertError) {
      setEditError('Failed to submit. Please try again.')
      setEditSubmitting(false)
      return
    }

    const editedId = selectedRow.pod_inventory_id
    closeModal()
    setPendingEditIds((prev) => new Set([...prev, editedId]))
    setToast('Submitted for warehouse review')
    setTimeout(() => setToast(null), 3000)
  }

  // Step 1: apply search + expiry filter
  const filtered = useMemo(() => {
    let result = rows

    if (search.trim()) {
      const q = search.toLowerCase()
      result = result.filter(
        (r) =>
          (r.boonz_products?.boonz_product_name ?? '').toLowerCase().includes(q) ||
          (r.machines?.official_name ?? '').toLowerCase().includes(q)
      )
    }

    result = result.filter((r) => {
      const days = daysUntilExpiry(r.expiration_date)
      switch (filter) {
        case 'expired': return days !== null && days <= 0
        case '3days':   return days !== null && days >= 0 && days <= 3
        case '7days':   return days !== null && days <= 7
        case '30days':  return days !== null && days <= 30
        case 'all':     return true
      }
    })

    return [...result].sort((a, b) => {
      const dir = sortDir === 'asc' ? 1 : -1
      if (sortField === 'expiry') {
        const da = daysUntilExpiry(a.expiration_date)
        const db = daysUntilExpiry(b.expiration_date)
        if (da === null && db === null) return (a.machines?.official_name ?? '—').localeCompare(b.machines?.official_name ?? '—')
        if (da === null) return 1   // nulls always last regardless of dir
        if (db === null) return -1
        if (da !== db) return (da - db) * dir
        return (a.machines?.official_name ?? '—').localeCompare(b.machines?.official_name ?? '—')
      }
      if (sortField === 'qty') {
        const diff = a.current_stock - b.current_stock
        if (diff !== 0) return diff * dir
        return (a.boonz_products?.boonz_product_name ?? '—').localeCompare(b.boonz_products?.boonz_product_name ?? '—')
      }
      // sortField === 'product'
      const cmp = (a.boonz_products?.boonz_product_name ?? '—').localeCompare(b.boonz_products?.boonz_product_name ?? '—')
      if (cmp !== 0) return cmp * dir
      return (a.machines?.official_name ?? '—').localeCompare(b.machines?.official_name ?? '—')
    })
  }, [rows, filter, search, sortField, sortDir])

  // Step 2: distinct machine names
  const machineOptions = useMemo((): string[] => {
    const names = new Set(filtered.map((r) => r.machines?.official_name ?? '—'))
    return Array.from(names).sort()
  }, [filtered])

  // Step 3: apply machine filter
  const machineFiltered = useMemo((): PodRow[] => {
    if (!selectedMachine) return filtered
    return filtered.filter((r) => (r.machines?.official_name ?? '—') === selectedMachine)
  }, [filtered, selectedMachine])

  // Step 4: build display groups
  const groups = useMemo((): DisplayGroup[] => {
    if (groupBy === 'none') return []

    const map = new Map<string, PodRow[]>()
    for (const row of machineFiltered) {
      const key = getGroupKey(row, groupBy)
      if (!map.has(key)) map.set(key, [])
      map.get(key)!.push(row)
    }

    const built: DisplayGroup[] = Array.from(map.entries()).map(([key, items]) => {
      const sorted = [...items].sort((a, b) => {
        if (a.expiration_date === null && b.expiration_date === null) {
          return groupBy === 'product'
            ? (a.machines?.official_name ?? '—').localeCompare(b.machines?.official_name ?? '—')
            : (a.boonz_products?.boonz_product_name ?? '—').localeCompare(b.boonz_products?.boonz_product_name ?? '—')
        }
        if (a.expiration_date === null) return 1
        if (b.expiration_date === null) return -1
        const dc = a.expiration_date.localeCompare(b.expiration_date)
        if (dc !== 0) return dc
        return groupBy === 'product'
          ? (a.machines?.official_name ?? '—').localeCompare(b.machines?.official_name ?? '—')
          : (a.boonz_products?.boonz_product_name ?? '—').localeCompare(b.boonz_products?.boonz_product_name ?? '—')
      })

      const totalUnits = sorted.reduce((sum, r) => sum + r.current_stock, 0)
      const isProductGroup = groupBy === 'product'
      const itemCount = isProductGroup
        ? new Set(sorted.map((r) => r.machines?.official_name ?? '—')).size
        : sorted.length
      const countLabel = isProductGroup ? 'machines' : 'items'

      return { key, headerLabel: key, itemCount, countLabel, totalUnits, items: sorted }
    })

    return built.sort((a, b) => b.totalUnits - a.totalUnits)
  }, [machineFiltered, groupBy])

  const totalUnits = useMemo(
    () => machineFiltered.reduce((sum, r) => sum + r.current_stock, 0),
    [machineFiltered]
  )

  const riskLabel = filter === 'expired' ? 'expired' : 'at risk'

  const summaryText = selectedMachine
    ? `${selectedMachine} · ${machineFiltered.length} items · ${totalUnits} units`
    : groupBy !== 'none'
    ? `${groups.length} groups · ${machineFiltered.length} items · ${totalUnits} units ${riskLabel}`
    : `${machineFiltered.length} items · ${totalUnits} units ${riskLabel}`

  const rp = rowProps(groupBy)

  if (loading) {
    return (
      <>
        <FieldHeader title="Machine Stock Expiry" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    )
  }

  return (
    <div className="pb-24">
      <FieldHeader title="Machine Stock Expiry" />

      <div className="px-4 py-4">
        {/* Search */}
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search product or machine…"
          className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
        />

        {/* Expiry filter pills */}
        <div className="mb-3 flex gap-2 overflow-x-auto pb-1">
          {FILTER_OPTIONS.map((f) => (
            <button
              key={f.value}
              onClick={() => handleFilterChange(f.value)}
              className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                filter === f.value
                  ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                  : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
              }`}
            >
              {f.label}
            </button>
          ))}
        </div>

        {/* Sort controls */}
        <div className="mb-3 flex items-center gap-1.5">
          <span className="shrink-0 text-xs text-neutral-400">Sort:</span>
          {(['expiry', 'qty', 'product'] as SortField[]).map((sf) => (
            <button
              key={sf}
              onClick={() => {
                if (sortField === sf) {
                  setSortDir((d) => (d === 'asc' ? 'desc' : 'asc'))
                } else {
                  setSortField(sf)
                  setSortDir('asc')
                }
              }}
              className={`flex items-center gap-0.5 rounded-full px-2.5 py-1 text-xs font-medium transition-colors ${
                sortField === sf
                  ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                  : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
              }`}
            >
              {sf === 'expiry' ? 'Expiry' : sf === 'qty' ? 'Qty' : 'Product'}
              {sortField === sf && (
                <span className="ml-0.5 text-[10px]">{sortDir === 'asc' ? '↑' : '↓'}</span>
              )}
            </button>
          ))}
        </div>

        {/* Controls row: machine dropdown + group by pills */}
        <div className="mb-3 flex items-center justify-between gap-3">
          <select
            value={selectedMachine ?? ''}
            onChange={(e) => setSelectedMachine(e.target.value || null)}
            className="min-w-0 flex-1 rounded-lg border border-neutral-300 bg-white px-3 py-1.5 text-xs text-neutral-700 dark:border-neutral-600 dark:bg-neutral-900 dark:text-neutral-300"
          >
            <option value="">All machines</option>
            {machineOptions.map((name) => (
              <option key={name} value={name}>
                {name}
              </option>
            ))}
          </select>

          <div className="flex shrink-0 gap-1">
            {GROUP_OPTIONS.map((g) => (
              <button
                key={g.value}
                onClick={() => setGroupBy(g.value)}
                className={`rounded-full px-2.5 py-1 text-xs font-medium transition-colors ${
                  groupBy === g.value
                    ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                    : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
                }`}
              >
                {g.label}
              </button>
            ))}
          </div>
        </div>

        {/* Summary line */}
        {machineFiltered.length > 0 && (
          <p className="mb-3 text-xs text-neutral-500">{summaryText}</p>
        )}

        {/* Results */}
        {machineFiltered.length === 0 ? (
          <div className="flex flex-col items-center justify-center p-8 text-center">
            <p className="mb-3 text-4xl">✓</p>
            <p className="text-base font-medium text-neutral-600 dark:text-neutral-400">
              No items in this category
            </p>
            <p className="mt-1 text-sm text-neutral-500">
              {search ? 'Try a different search term' : 'All clear for this range'}
            </p>
          </div>
        ) : groupBy !== 'none' ? (
          <div className="space-y-5">
            {groups.map((group) => (
              <div key={group.key}>
                <SectionHeader
                  label={group.headerLabel}
                  itemCount={group.itemCount}
                  unitCount={group.totalUnits}
                  countLabel={group.countLabel}
                />
                <ul className="space-y-2">
                  {group.items.map((row) => (
                    <PodRowItem
                      key={row.pod_inventory_id}
                      row={row}
                      {...rp}
                      isPending={pendingEditIds.has(row.pod_inventory_id)}
                      onClick={() => setSelectedRow(row)}
                    />
                  ))}
                </ul>
              </div>
            ))}
          </div>
        ) : (
          <ul className="space-y-2">
            {machineFiltered.map((row) => (
              <PodRowItem
                key={row.pod_inventory_id}
                row={row}
                {...rp}
                isPending={pendingEditIds.has(row.pod_inventory_id)}
                onClick={() => setSelectedRow(row)}
              />
            ))}
          </ul>
        )}
      </div>

      {/* ── Edit modal (bottom sheet) ── */}
      {selectedRow && (
        <div className="fixed inset-0 z-50 flex flex-col justify-end">
          {/* Backdrop */}
          <div className="absolute inset-0 bg-black/40" onClick={closeModal} />

          {/* Sheet */}
          <div className="relative z-10 max-h-[90vh] overflow-y-auto rounded-t-2xl bg-white px-4 pt-5 pb-10 shadow-xl dark:bg-neutral-900">
            {/* Header */}
            <div className="mb-4">
              <p className="text-base font-bold">{selectedRow.boonz_products?.boonz_product_name ?? '—'}</p>
              <p className="text-sm text-neutral-500">{selectedRow.machines?.official_name ?? '—'}</p>
              <p className="mt-1 text-xs text-neutral-400">
                {selectedRow.current_stock} units · expires {formatDate(selectedRow.expiration_date)}
              </p>
            </div>

            <p className="mb-3 text-sm font-semibold text-neutral-700 dark:text-neutral-300">
              What is the current status of this item?
            </p>

            {/* Type buttons */}
            <div className="mb-4 space-y-2">
              {/* Still in stock */}
              <button
                onClick={() => setEditType('in_stock')}
                className={`w-full rounded-xl border-2 p-3 text-left transition-colors ${
                  editType === 'in_stock'
                    ? 'border-green-500 bg-green-50 dark:border-green-600 dark:bg-green-950'
                    : 'border-neutral-200 bg-white dark:border-neutral-700 dark:bg-neutral-800'
                }`}
              >
                <p className="text-sm font-semibold">✅ Still in stock</p>
                <p className="text-xs text-neutral-500">Product is present and not expired</p>
              </button>

              {/* Sold / consumed */}
              <button
                onClick={() => { setEditType('sold'); setEditQty(0) }}
                className={`w-full rounded-xl border-2 p-3 text-left transition-colors ${
                  editType === 'sold'
                    ? 'border-blue-500 bg-blue-50 dark:border-blue-600 dark:bg-blue-950'
                    : 'border-neutral-200 bg-white dark:border-neutral-700 dark:bg-neutral-800'
                }`}
              >
                <p className="text-sm font-semibold">💰 Sold / consumed</p>
                <p className="text-xs text-neutral-500">Product was purchased by a customer</p>
              </button>
              {editType === 'sold' && (
                <div className="ml-4">
                  <label className="mb-1 block text-xs text-neutral-500">
                    How many units sold?
                  </label>
                  <input
                    type="number"
                    min={0}
                    max={selectedRow.current_stock}
                    value={editQty || ''}
                    onChange={(e) => setEditQty(parseInt(e.target.value, 10) || 0)}
                    className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                    placeholder="0"
                  />
                </div>
              )}

              {/* Damaged */}
              <button
                onClick={() => { setEditType('damaged'); setEditQty(0) }}
                className={`w-full rounded-xl border-2 p-3 text-left transition-colors ${
                  editType === 'damaged'
                    ? 'border-red-500 bg-red-50 dark:border-red-600 dark:bg-red-950'
                    : 'border-neutral-200 bg-white dark:border-neutral-700 dark:bg-neutral-800'
                }`}
              >
                <p className="text-sm font-semibold">🔴 Damaged</p>
                <p className="text-xs text-neutral-500">Product is damaged or unusable</p>
              </button>
              {editType === 'damaged' && (
                <div className="ml-4 space-y-3">
                  <div>
                    <label className="mb-1 block text-xs text-neutral-500">
                      How many units damaged?
                    </label>
                    <input
                      type="number"
                      min={0}
                      max={selectedRow.current_stock}
                      value={editQty || ''}
                      onChange={(e) => setEditQty(parseInt(e.target.value, 10) || 0)}
                      className="w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                      placeholder="0"
                    />
                  </div>
                  <div>
                    <label className="mb-1 block text-xs text-neutral-500">
                      Photo (optional)
                    </label>
                    {editPhotoUrl ? (
                      <div className="relative">
                        {/* eslint-disable-next-line @next/next/no-img-element */}
                        <img
                          src={editPhotoUrl}
                          alt="Damage photo"
                          className="h-32 w-full rounded-lg object-cover"
                        />
                        <button
                          onClick={() => {
                            setEditPhoto(null)
                            if (editPhotoUrl) URL.revokeObjectURL(editPhotoUrl)
                            setEditPhotoUrl(null)
                          }}
                          className="absolute right-2 top-2 rounded-full bg-black/50 px-2 py-0.5 text-xs text-white"
                        >
                          Remove
                        </button>
                      </div>
                    ) : (
                      <label className="flex cursor-pointer items-center gap-2 rounded-lg border border-dashed border-neutral-300 p-3 text-sm text-neutral-500 hover:bg-neutral-50 dark:border-neutral-600 dark:hover:bg-neutral-800">
                        <span>📷 Capture photo</span>
                        <input
                          type="file"
                          accept="image/*"
                          capture="environment"
                          className="sr-only"
                          onChange={(e) => {
                            const file = e.target.files?.[0]
                            if (!file) return
                            setEditPhoto(file)
                            setEditPhotoUrl(URL.createObjectURL(file))
                          }}
                        />
                      </label>
                    )}
                  </div>
                </div>
              )}
            </div>

            {/* Notes */}
            <input
              type="text"
              value={editNotes}
              onChange={(e) => setEditNotes(e.target.value)}
              placeholder="Add a note… (optional)"
              className="mb-4 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
            />

            {editError && (
              <p className="mb-3 text-sm text-red-600 dark:text-red-400">{editError}</p>
            )}

            {/* Action buttons */}
            <div className="space-y-2">
              <button
                onClick={submitEdit}
                disabled={!editType || editSubmitting}
                className="w-full rounded-xl bg-neutral-900 py-3 text-sm font-semibold text-white disabled:opacity-40 dark:bg-neutral-100 dark:text-neutral-900"
              >
                {editSubmitting ? 'Submitting…' : 'Submit for review'}
              </button>
              <button
                onClick={closeModal}
                className="w-full rounded-xl border border-neutral-300 py-3 text-sm font-medium text-neutral-700 dark:border-neutral-600 dark:text-neutral-300"
              >
                Cancel
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Toast */}
      {toast && (
        <div className="fixed bottom-24 left-4 right-4 z-50 rounded-xl bg-green-100 px-4 py-3 text-center text-sm font-medium text-green-800 shadow-lg dark:bg-green-900 dark:text-green-200">
          {toast}
        </div>
      )}
    </div>
  )
}
