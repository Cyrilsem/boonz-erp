'use client'

import { useEffect, useState, useMemo } from 'react'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../components/field-header'

// ─── Data types ───────────────────────────────────────────────────────────────

interface PodRow {
  pod_inventory_id: string
  boonz_product_name: string
  product_category: string
  machine_name: string
  current_stock: number
  expiration_date: string | null
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

// ─── Static config ────────────────────────────────────────────────────────────

const FILTER_OPTIONS: { label: string; value: PodFilter }[] = [
  { label: 'Expired', value: 'expired' },
  { label: '< 3 days', value: '3days' },
  { label: '< 7 days', value: '7days' },
  { label: '< 30 days', value: '30days' },
  { label: 'All active', value: 'all' },
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
  all: 'none',
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
    case 'machine':   return row.machine_name
    case 'product':   return row.boonz_product_name
    case 'category':  return row.product_category
  }
}

// ─── Sub-components ───────────────────────────────────────────────────────────

function PodExpiryBadge({ days }: { days: number | null }) {
  if (days === null) return null
  if (days <= 0) {
    return (
      <span className="rounded-full bg-red-100 px-3 py-1 text-sm font-semibold text-red-700 dark:bg-red-900 dark:text-red-300">
        Expired
      </span>
    )
  }
  const label = `${days}d left`
  if (days <= 3) {
    return (
      <span className="rounded-full bg-red-100 px-3 py-1 text-sm font-semibold text-red-700 dark:bg-red-900 dark:text-red-300">
        {label}
      </span>
    )
  }
  if (days <= 7) {
    return (
      <span className="rounded-full bg-amber-100 px-3 py-1 text-sm font-semibold text-amber-700 dark:bg-amber-900 dark:text-amber-300">
        {label}
      </span>
    )
  }
  return (
    <span className="rounded-full bg-orange-100 px-3 py-1 text-sm font-semibold text-orange-700 dark:bg-orange-900 dark:text-orange-300">
      {label}
    </span>
  )
}

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
  showProduct: boolean   // true → line 1 = product name; false → line 1 = machine name
  showMachine: boolean   // show machine name on line 2 (only when showProduct=true)
  showCategory: boolean  // show product_category on line 2 (takes precedence over showMachine)
}

function PodRowItem({ row, showProduct, showMachine, showCategory }: PodRowItemProps) {
  const days = daysUntilExpiry(row.expiration_date)
  const qtyColour =
    days !== null && days <= 0
      ? 'text-red-600 dark:text-red-400'
      : days !== null && days <= 3
      ? 'text-amber-600 dark:text-amber-400'
      : 'text-neutral-700 dark:text-neutral-300'

  // Line 1: product name if showProduct, otherwise machine name (product grouping)
  const line1 = showProduct ? row.boonz_product_name : row.machine_name

  // Line 2: only meaningful when line 1 is the product name
  const line2: string | null = showProduct
    ? showCategory
      ? row.product_category
      : showMachine
      ? row.machine_name
      : null
    : null

  return (
    <li className="flex items-start rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
      {/* Left side */}
      <div className="min-w-0 flex-1 pr-3">
        <p className="truncate text-sm font-bold">{line1}</p>
        {line2 !== null && (
          <p className="mt-0.5 truncate text-xs text-neutral-500">{line2}</p>
        )}
        <div className="mt-1.5 flex flex-wrap items-center gap-2">
          <span className="text-xs text-neutral-400">{formatDate(row.expiration_date)}</span>
          <PodExpiryBadge days={days} />
        </div>
      </div>

      {/* Right side: qty */}
      <div className={`flex shrink-0 flex-col items-end ${qtyColour}`}>
        <p className="text-xl font-bold leading-none">{row.current_stock}</p>
        <p className="mt-0.5 text-xs opacity-60">units</p>
      </div>
    </li>
  )
}

// ─── Row props per groupBy ────────────────────────────────────────────────────

function rowProps(groupBy: GroupBy): Omit<PodRowItemProps, 'row'> {
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
  const [filter, setFilter] = useState<PodFilter>('7days')
  const [groupBy, setGroupBy] = useState<GroupBy>(DEFAULT_GROUP_BY['7days'])
  const [selectedMachine, setSelectedMachine] = useState<string | null>(null)
  const [search, setSearch] = useState('')

  // Reset group + machine when expiry filter changes
  function handleFilterChange(newFilter: PodFilter) {
    setFilter(newFilter)
    setGroupBy(DEFAULT_GROUP_BY[newFilter])
    setSelectedMachine(null)
  }

  useEffect(() => {
    async function fetchData() {
      const supabase = createClient()

      const { data, error } = await supabase
        .from('pod_inventory')
        .select(`
          pod_inventory_id,
          current_stock,
          expiration_date,
          status,
          boonz_products ( boonz_product_name, product_category ),
          machines ( official_name )
        `)
        .eq('status', 'Active')
        .gt('current_stock', 0)
        .order('expiration_date', { ascending: true })

      console.log('[PodInventory] fetch:', data?.length, error)

      if (data) {
        const mapped: PodRow[] = data.map((row) => {
          const p = row.boonz_products as unknown as {
            boonz_product_name: string
            product_category: string | null
          } | null
          const m = row.machines as unknown as { official_name: string } | null
          return {
            pod_inventory_id: row.pod_inventory_id,
            boonz_product_name: p?.boonz_product_name ?? '—',
            product_category: p?.product_category ?? 'Uncategorised',
            machine_name: m?.official_name ?? '—',
            current_stock: row.current_stock ?? 0,
            expiration_date: row.expiration_date,
          }
        })
        setRows(mapped)
      }
      setLoading(false)
    }
    fetchData()
  }, [])

  // Step 1: apply search + expiry filter (feeds machine dropdown)
  const filtered = useMemo(() => {
    let result = rows

    if (search.trim()) {
      const q = search.toLowerCase()
      result = result.filter(
        (r) =>
          r.boonz_product_name.toLowerCase().includes(q) ||
          r.machine_name.toLowerCase().includes(q)
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

    // Sorted: expiry ASC → machine name ASC
    return [...result].sort((a, b) => {
      const da = daysUntilExpiry(a.expiration_date)
      const db = daysUntilExpiry(b.expiration_date)
      if (da === null && db === null) return a.machine_name.localeCompare(b.machine_name)
      if (da === null) return 1
      if (db === null) return -1
      if (da !== db) return da - db
      return a.machine_name.localeCompare(b.machine_name)
    })
  }, [rows, filter, search])

  // Step 2: distinct machine names from expiry-filtered data (for dropdown)
  const machineOptions = useMemo((): string[] => {
    const names = new Set(filtered.map((r) => r.machine_name))
    return Array.from(names).sort()
  }, [filtered])

  // Step 3: apply machine filter on top of expiry-filtered data
  const machineFiltered = useMemo((): PodRow[] => {
    if (!selectedMachine) return filtered
    return filtered.filter((r) => r.machine_name === selectedMachine)
  }, [filtered, selectedMachine])

  // Step 4: build display groups (only when groupBy !== 'none')
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
            ? a.machine_name.localeCompare(b.machine_name)
            : a.boonz_product_name.localeCompare(b.boonz_product_name)
        }
        if (a.expiration_date === null) return 1
        if (b.expiration_date === null) return -1
        const dc = a.expiration_date.localeCompare(b.expiration_date)
        if (dc !== 0) return dc
        return groupBy === 'product'
          ? a.machine_name.localeCompare(b.machine_name)
          : a.boonz_product_name.localeCompare(b.boonz_product_name)
      })

      const totalUnits = sorted.reduce((sum, r) => sum + r.current_stock, 0)

      // Product grouping counts distinct machines; all others count items
      const isProductGroup = groupBy === 'product'
      const itemCount = isProductGroup
        ? new Set(sorted.map((r) => r.machine_name)).size
        : sorted.length
      const countLabel = isProductGroup ? 'machines' : 'items'

      return { key, headerLabel: key, itemCount, countLabel, totalUnits, items: sorted }
    })

    // Sort groups by totalUnits DESC
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

        {/* Controls row: machine dropdown + group by pills */}
        <div className="mb-3 flex items-center justify-between gap-3">
          {/* LEFT: Machine dropdown */}
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

          {/* RIGHT: Group by pills */}
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
          /* Grouped view */
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
                    <PodRowItem key={row.pod_inventory_id} row={row} {...rp} />
                  ))}
                </ul>
              </div>
            ))}
          </div>
        ) : (
          /* Flat list */
          <ul className="space-y-2">
            {machineFiltered.map((row) => (
              <PodRowItem key={row.pod_inventory_id} row={row} {...rp} />
            ))}
          </ul>
        )}
      </div>
    </div>
  )
}
