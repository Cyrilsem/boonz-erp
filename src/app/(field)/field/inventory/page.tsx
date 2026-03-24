'use client'

import { useEffect, useState, useCallback, useMemo } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../components/field-header'
import { getExpiryStyle } from '@/app/(field)/utils/expiry'
import { usePageTour } from '../../components/onboarding/use-page-tour'
import Tour from '../../components/onboarding/tour'

interface InventoryRow {
  wh_inventory_id: string
  boonz_product_id: string
  boonz_product_name: string
  product_category: string | null
  batch_id: string
  wh_location: string | null
  warehouse_stock: number
  expiration_date: string | null
  status: string
}

interface ControlEdit {
  qty: number
  location: string
  status: string
}

type ExpiryFilter = 'all' | 'expired' | '3days' | '7days' | '30days'
type SortOption = 'expiry' | 'location' | 'name' | 'qty_high' | 'qty_low'
type StatusFilter = 'All' | 'Active' | 'Expired' | 'Inactive'
type GroupBy = 'category' | 'product' | 'location' | 'none'

// ─── Pending review types ──────────────────────────────────────────────────────

const REVIEWER_ROLES = ['warehouse', 'operator_admin', 'manager', 'superadmin'] as const

interface PendingEdit {
  edit_id: string
  pod_inventory_id: string
  machine_id: string
  boonz_product_id: string
  edit_type: 'sold' | 'partial_sold' | 'damaged' | 'expired' | 'in_stock' | 'return_to_warehouse'
  quantity_update: number | null
  notes: string | null
  created_at: string
  machine_name: string
  boonz_product_name: string
  submitted_by_name: string | null
}

function formatTimeAgo(dateStr: string): string {
  const diffMs = Date.now() - new Date(dateStr).getTime()
  const mins = Math.floor(diffMs / 60000)
  if (mins < 60) return `${mins}m ago`
  const hrs = Math.floor(mins / 60)
  if (hrs < 24) return `${hrs}h ago`
  return `${Math.floor(hrs / 24)}d ago`
}

interface InventoryGroup {
  key: string
  items: InventoryRow[]
  totalUnits: number
}

const expiryFilters: { label: string; value: ExpiryFilter }[] = [
  { label: 'All', value: 'all' },
  { label: 'Expired', value: 'expired' },
  { label: '<=3 days', value: '3days' },
  { label: '<=7 days', value: '7days' },
  { label: '<=30 days', value: '30days' },
]

function daysUntilExpiry(date: string | null): number | null {
  if (!date) return null
  const today = new Date()
  today.setHours(0, 0, 0, 0)
  const exp = new Date(date + 'T00:00:00')
  return Math.ceil((exp.getTime() - today.getTime()) / (1000 * 60 * 60 * 24))
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return '\u2014'
  const d = new Date(dateStr + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
}


function ExpiryBadge({ expiryDate }: { expiryDate: string | null }) {
  const style = getExpiryStyle(expiryDate)
  if (!style.label) return null
  return (
    <span className={`rounded-full ${style.badgeBg} px-2 py-0.5 text-xs font-medium ${style.badgeText}`}>
      {style.label}
    </span>
  )
}

function SectionHeader({
  label,
  itemCount,
  countLabel,
  totalUnits,
}: {
  label: string
  itemCount: number
  countLabel: string
  totalUnits: number
}) {
  return (
    <div className="flex items-center gap-2 mt-4 mb-2">
      <span className="shrink-0 text-sm font-semibold text-neutral-700 dark:text-neutral-300">{label}</span>
      <span className="shrink-0 text-xs text-neutral-500">
        {itemCount} {countLabel} · {totalUnits} units
      </span>
      <hr className="flex-1 border-neutral-200 dark:border-neutral-700" />
    </div>
  )
}

export default function InventoryPage() {
  const [rows, setRows] = useState<InventoryRow[]>([])
  const [loading, setLoading] = useState(true)
  const { showTour, tourSteps, completeTour } = usePageTour('inventory')
  const [search, setSearch] = useState('')
  const [expiryFilter, setExpiryFilter] = useState<ExpiryFilter>('7days')
  const [sortBy, setSortBy] = useState<SortOption>('expiry')
  const [hideEmpty, setHideEmpty] = useState(true)
  const [statusFilter, setStatusFilter] = useState<StatusFilter>('Active')
  const [groupBy, setGroupBy] = useState<GroupBy>('none')

  // Pending reviews
  const [userRole, setUserRole] = useState<string | null>(null)
  const [pendingEdits, setPendingEdits] = useState<PendingEdit[]>([])
  const [reviewExpanded, setReviewExpanded] = useState(true)
  const [processingIds, setProcessingIds] = useState<Set<string>>(new Set())
  const [reviewToast, setReviewToast] = useState<string | null>(null)

  // Inventory control mode
  const [controlMode, setControlMode] = useState(false)
  const [controlEdits, setControlEdits] = useState<Map<string, ControlEdit>>(new Map())
  const [controlSaving, setControlSaving] = useState(false)
  const [controlMessage, setControlMessage] = useState<string | null>(null)

  const fetchData = useCallback(async () => {
    const supabase = createClient()

    const query = supabase
      .from('warehouse_inventory')
      .select(`
        wh_inventory_id,
        boonz_product_id,
        batch_id,
        wh_location,
        warehouse_stock,
        expiration_date,
        status,
        boonz_products!inner(boonz_product_name, product_category)
      `)

    const { data } = await query

    if (!data || data.length === 0) {
      setRows([])
      setLoading(false)
      return
    }

    const mapped: InventoryRow[] = data.map((row) => {
      const p = row.boonz_products as unknown as {
        boonz_product_name: string
        product_category: string | null
      }
      return {
        wh_inventory_id: row.wh_inventory_id,
        boonz_product_id: row.boonz_product_id,
        boonz_product_name: p.boonz_product_name,
        product_category: p.product_category,
        batch_id: row.batch_id ?? '',
        wh_location: row.wh_location,
        warehouse_stock: row.warehouse_stock ?? 0,
        expiration_date: row.expiration_date,
        status: row.status ?? 'Active',
      }
    })

    setRows(mapped)
    setLoading(false)
  }, [])

  const fetchUserRole = useCallback(async () => {
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) return
    const { data } = await supabase
      .from('user_profiles')
      .select('role')
      .eq('id', user.id)
      .single()
    setUserRole(data?.role ?? null)
  }, [])

  const fetchPendingEdits = useCallback(async () => {
    const supabase = createClient()
    const { data } = await supabase
      .from('pod_inventory_edits')
      .select(`
        edit_id, pod_inventory_id, machine_id, boonz_product_id,
        edit_type, quantity_update, notes, status, created_at, requested_by,
        machines!inner(official_name),
        boonz_products!inner(boonz_product_name)
      `)
      .eq('status', 'pending')
      .order('created_at', { ascending: true })

    if (!data || data.length === 0) {
      setPendingEdits([])
      return
    }

    const userIds = [
      ...new Set(
        data
          .map(r => r.requested_by as string | null)
          .filter((id): id is string => id !== null)
      ),
    ]
    const { data: profiles } = await supabase
      .from('user_profiles')
      .select('id, full_name')
      .in('id', userIds)
    const nameMap = new Map<string, string | null>(
      (profiles ?? []).map(p => [p.id as string, p.full_name as string | null])
    )

    setPendingEdits(
      data.map(r => {
        const m = r.machines as unknown as { official_name: string }
        const bp = r.boonz_products as unknown as { boonz_product_name: string }
        const reqBy = r.requested_by as string | null
        return {
          edit_id: r.edit_id,
          pod_inventory_id: r.pod_inventory_id,
          machine_id: r.machine_id,
          boonz_product_id: r.boonz_product_id,
          edit_type: r.edit_type as 'sold' | 'partial_sold' | 'damaged' | 'expired' | 'in_stock' | 'return_to_warehouse',
          quantity_update: r.quantity_update as number | null,
          notes: r.notes as string | null,
          created_at: r.created_at as string,
          machine_name: m.official_name,
          boonz_product_name: bp.boonz_product_name,
          submitted_by_name: reqBy ? (nameMap.get(reqBy) ?? null) : null,
        }
      })
    )
  }, [])

  useEffect(() => {
    fetchData()
    fetchUserRole()
    fetchPendingEdits()
  }, [fetchData, fetchUserRole, fetchPendingEdits])

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === 'visible') {
        fetchData()
        fetchPendingEdits()
      }
    }
    function handleFocus() {
      fetchData()
      fetchPendingEdits()
    }
    document.addEventListener('visibilitychange', handleVisibility)
    window.addEventListener('focus', handleFocus)
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility)
      window.removeEventListener('focus', handleFocus)
    }
  }, [fetchData, fetchPendingEdits])

  // Enter control mode: initialize edits from current rows
  function enterControlMode() {
    const edits = new Map<string, ControlEdit>()
    for (const row of rows) {
      edits.set(row.wh_inventory_id, {
        qty: row.warehouse_stock,
        location: row.wh_location ?? '',
        status: row.status,
      })
    }
    setControlEdits(edits)
    setControlMode(true)
  }

  function updateControlEdit(id: string, field: keyof ControlEdit, value: string | number) {
    setControlEdits((prev) => {
      const next = new Map(prev)
      const existing = next.get(id)
      if (existing) {
        next.set(id, { ...existing, [field]: value })
      }
      return next
    })
  }

  async function completeControl() {
    setControlSaving(true)
    const supabase = createClient()

    const { data: { user } } = await supabase.auth.getUser()
    const userId = user?.id

    for (const row of rows) {
      const edit = controlEdits.get(row.wh_inventory_id)
      if (!edit) continue

      const qtyChanged = edit.qty !== row.warehouse_stock
      const locationChanged = (edit.location || null) !== (row.wh_location || null)
      const statusChanged = edit.status !== row.status

      if (!qtyChanged && !locationChanged && !statusChanged) continue

      // Update the inventory row
      const updates: Record<string, unknown> = {}
      if (qtyChanged) updates.warehouse_stock = edit.qty
      if (locationChanged) updates.wh_location = edit.location || null
      if (statusChanged) updates.status = edit.status

      await supabase
        .from('warehouse_inventory')
        .update(updates)
        .eq('wh_inventory_id', row.wh_inventory_id)

      // Insert audit log
      await supabase.from('inventory_audit_log').insert({
        wh_inventory_id: row.wh_inventory_id,
        boonz_product_id: row.boonz_product_id,
        old_qty: row.warehouse_stock,
        new_qty: edit.qty,
        reason: 'Inventory control',
      })
    }

    // Insert inventory control log
    if (userId) {
      await supabase.from('inventory_control_log').insert({
        conducted_by: userId,
        notes: null,
      })
    }

    setControlMode(false)
    setControlEdits(new Map())
    setControlSaving(false)
    setControlMessage('Inventory control logged')
    await fetchData()

    setTimeout(() => setControlMessage(null), 3000)
  }

  // ─── Review handlers ────────────────────────────────────────────────────────

  function showReviewToast(msg: string) {
    setReviewToast(msg)
    setTimeout(() => setReviewToast(null), 3000)
  }

  async function handleApprove(editId: string, edit: PendingEdit) {
    setProcessingIds(prev => new Set([...prev, editId]))
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()

    await supabase
      .from('pod_inventory_edits')
      .update({
        status: 'approved',
        reviewed_by: user?.id ?? null,
        reviewed_at: new Date().toISOString(),
      })
      .eq('edit_id', editId)

    if (edit.edit_type === 'expired') {
      // ── Expired: 4-step flow, all steps non-blocking ──────────────────────
      const today = new Date().toISOString().split('T')[0]

      // Step 1: get expiration_date from pod_inventory
      let podExpiryDate: string | null = null
      try {
        const { data: podRow } = await supabase
          .from('pod_inventory')
          .select('expiration_date')
          .eq('pod_inventory_id', edit.pod_inventory_id)
          .limit(1)
          .single()
        podExpiryDate = podRow?.expiration_date ?? null
      } catch (e) {
        console.error('[approve expired] step 1 failed', e)
      }

      // Step 2: zero-out pod_inventory and mark removed
      try {
        await supabase
          .from('pod_inventory')
          .update({ current_stock: 0, status: 'Removed / Expired', snapshot_date: today })
          .eq('pod_inventory_id', edit.pod_inventory_id)
      } catch (e) {
        console.error('[approve expired] step 2 failed', e)
      }

      // Step 3: find matching warehouse batch and mark as Expired
      let whBatchFound = false
      try {
        const baseQuery = supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id')
          .eq('boonz_product_id', edit.boonz_product_id)
          .eq('status', 'Active')
          .order('expiration_date', { ascending: true, nullsFirst: false })
          .limit(1)

        const { data: whBatch } = podExpiryDate
          ? await baseQuery.or(`expiration_date.eq.${podExpiryDate},expiration_date.is.null`)
          : await baseQuery

        if (whBatch && whBatch.length > 0) {
          whBatchFound = true
          const batchId = whBatch[0].wh_inventory_id
          console.log('[Approve expired] warehouse batch found and marked Expired:', batchId)
          await supabase
            .from('warehouse_inventory')
            .update({ status: 'Expired', warehouse_stock: 0, snapshot_date: today })
            .eq('wh_inventory_id', batchId)
        }
      } catch (e) {
        console.error('[approve expired] step 3 failed', e)
      }

      // Step 4: if no warehouse batch found, insert a returned-expired record
      if (!whBatchFound) {
        console.log('[Approve expired] no warehouse batch found, inserting Expired record')
        try {
          await supabase.from('warehouse_inventory').insert({
            boonz_product_id: edit.boonz_product_id,
            warehouse_stock: 0,
            expiration_date: podExpiryDate,
            batch_id: `RETURNED-EXPIRED-${today}`,
            status: 'Expired',
            snapshot_date: today,
          })
        } catch (e) {
          console.error('[approve expired] step 4 failed', e)
        }
      }
    } else if (edit.edit_type === 'return_to_warehouse') {
      // ── Return to warehouse: zero pod + insert active WH row ─────────────
      const today = new Date().toISOString().split('T')[0]

      // Step 1: get expiration_date from pod_inventory
      let podExpiryDate: string | null = null
      try {
        const { data: podRow } = await supabase
          .from('pod_inventory')
          .select('expiration_date')
          .eq('pod_inventory_id', edit.pod_inventory_id)
          .limit(1)
          .single()
        podExpiryDate = podRow?.expiration_date ?? null
      } catch (e) {
        console.error('[approve return_to_warehouse] step 1 failed', e)
      }

      // Step 2: zero-out pod_inventory and mark Removed
      try {
        await supabase
          .from('pod_inventory')
          .update({ current_stock: 0, status: 'Removed', snapshot_date: today })
          .eq('pod_inventory_id', edit.pod_inventory_id)
      } catch (e) {
        console.error('[approve return_to_warehouse] step 2 failed', e)
      }

      // Step 3: insert Active warehouse row (stock returns as reusable)
      try {
        await supabase.from('warehouse_inventory').insert({
          boonz_product_id: edit.boonz_product_id,
          warehouse_stock: edit.quantity_update ?? 0,
          expiration_date: podExpiryDate,
          batch_id: `RETURNED-FROM-POD-${today}`,
          status: 'Active',
          snapshot_date: today,
        })
      } catch (e) {
        console.error('[approve return_to_warehouse] step 3 failed', e)
      }
    } else {
      // ── All other types: update pod_inventory ─────────────────────────────
      try {
        const qty = edit.quantity_update ?? 0
        if (edit.edit_type === 'sold' || edit.edit_type === 'partial_sold' || edit.edit_type === 'damaged') {
          const { data: podRow } = await supabase
            .from('pod_inventory')
            .select('current_stock')
            .eq('pod_inventory_id', edit.pod_inventory_id)
            .single()
          if (podRow) {
            await supabase
              .from('pod_inventory')
              .update({ current_stock: Math.max(0, (podRow.current_stock ?? 0) - qty) })
              .eq('pod_inventory_id', edit.pod_inventory_id)
          }
        } else {
          // in_stock: set to the reported quantity
          await supabase
            .from('pod_inventory')
            .update({ current_stock: qty })
            .eq('pod_inventory_id', edit.pod_inventory_id)
        }
      } catch {
        // Non-blocking: edit record is already approved
      }
    }

    setPendingEdits(prev => prev.filter(e => e.edit_id !== editId))
    setProcessingIds(prev => { const s = new Set(prev); s.delete(editId); return s })
    showReviewToast('Edit approved')
  }

  async function handleReject(editId: string) {
    setProcessingIds(prev => new Set([...prev, editId]))
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()

    await supabase
      .from('pod_inventory_edits')
      .update({
        status: 'rejected',
        reviewed_by: user?.id ?? null,
        reviewed_at: new Date().toISOString(),
      })
      .eq('edit_id', editId)

    setPendingEdits(prev => prev.filter(e => e.edit_id !== editId))
    setProcessingIds(prev => { const s = new Set(prev); s.delete(editId); return s })
    showReviewToast('Edit rejected')
  }

  const processed: InventoryRow[] = useMemo(() => {
    let filtered = rows

    // Status filter
    if (statusFilter !== 'All') {
      filtered = filtered.filter((r) => r.status === statusFilter)
    }

    // Hide empty
    if (hideEmpty) {
      filtered = filtered.filter((r) => r.warehouse_stock > 0)
    }

    // Search filter
    if (search.trim()) {
      const q = search.toLowerCase()
      filtered = filtered.filter((r) =>
        r.boonz_product_name.toLowerCase().includes(q)
      )
    }

    // Expiry filter
    filtered = filtered.filter((r) => {
      if (expiryFilter === 'all') return true
      const days = daysUntilExpiry(r.expiration_date)
      if (days === null) return false
      switch (expiryFilter) {
        case 'expired': return days <= 0
        case '3days': return days <= 3
        case '7days': return days <= 7
        case '30days': return days <= 30
      }
    })

    // Sort
    filtered = [...filtered].sort((a, b) => {
      switch (sortBy) {
        case 'expiry': {
          const da = daysUntilExpiry(a.expiration_date)
          const db = daysUntilExpiry(b.expiration_date)
          if (da === null && db === null) return 0
          if (da === null) return 1
          if (db === null) return -1
          return da - db
        }
        case 'location': {
          const la = a.wh_location ?? ''
          const lb = b.wh_location ?? ''
          return la.localeCompare(lb)
        }
        case 'name':
          return a.boonz_product_name.localeCompare(b.boonz_product_name)
        case 'qty_high':
          return b.warehouse_stock - a.warehouse_stock
        case 'qty_low':
          return a.warehouse_stock - b.warehouse_stock
      }
    })

    return filtered
  }, [rows, search, expiryFilter, sortBy, hideEmpty, statusFilter])

  const groups: InventoryGroup[] = useMemo(() => {
    if (groupBy === 'none') return []

    const map = new Map<string, InventoryRow[]>()
    for (const row of processed) {
      let key: string
      if (groupBy === 'category') key = row.product_category ?? 'Uncategorised'
      else if (groupBy === 'product') key = row.boonz_product_name
      else key = row.wh_location ?? 'No location'

      const existing = map.get(key)
      if (existing) existing.push(row)
      else map.set(key, [row])
    }

    const result: InventoryGroup[] = Array.from(map.entries()).map(([key, items]) => ({
      key,
      items,
      totalUnits: items.reduce((s, r) => s + r.warehouse_stock, 0),
    }))

    // Sort groups: location → alpha; category/product → totalUnits DESC
    if (groupBy === 'location') {
      result.sort((a, b) => a.key.localeCompare(b.key))
    } else {
      result.sort((a, b) => b.totalUnits - a.totalUnits)
    }

    // Sort items within each group
    for (const group of result) {
      group.items.sort((a, b) => {
        const da = daysUntilExpiry(a.expiration_date)
        const db = daysUntilExpiry(b.expiration_date)
        const secondaryA = groupBy === 'product' ? (a.wh_location ?? '') : a.boonz_product_name
        const secondaryB = groupBy === 'product' ? (b.wh_location ?? '') : b.boonz_product_name
        if (da === null && db === null) return secondaryA.localeCompare(secondaryB)
        if (da === null) return 1
        if (db === null) return -1
        const diff = da - db
        return diff !== 0 ? diff : secondaryA.localeCompare(secondaryB)
      })
    }

    return result
  }, [processed, groupBy])

  if (loading) {
    return (
      <>
        <FieldHeader title="Inventory" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading inventory...</p>
        </div>
      </>
    )
  }

  return (
    <div className="pb-24">
      <FieldHeader
        title="Inventory"
        rightAction={
          !controlMode ? (
            <button
              onClick={enterControlMode}
              className="rounded-lg bg-blue-600 px-3 py-1.5 text-xs font-medium text-white hover:bg-blue-700"
            >
              + Inventory Control
            </button>
          ) : (
            <button
              onClick={() => { setControlMode(false); setControlEdits(new Map()) }}
              className="rounded-lg bg-neutral-200 px-3 py-1.5 text-xs font-medium text-neutral-700 hover:bg-neutral-300 dark:bg-neutral-700 dark:text-neutral-200 dark:hover:bg-neutral-600"
            >
              Cancel
            </button>
          )
        }
      />

      {showTour && tourSteps.length > 0 && (
        <Tour steps={tourSteps} onComplete={completeTour} onSkip={completeTour} />
      )}
      <div className="px-4 py-4">
        {/* Control mode message */}
        {controlMessage && (
          <div className="mb-3 rounded-lg bg-green-100 px-3 py-2 text-sm font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
            {controlMessage}
          </div>
        )}

        {/* ── Pending Reviews section ── */}
        {userRole && (REVIEWER_ROLES as readonly string[]).includes(userRole) && pendingEdits.length > 0 && (
          <div className="mb-4">
            <button
              onClick={() => setReviewExpanded(e => !e)}
              className="flex w-full items-center gap-2 rounded-xl border border-amber-200 bg-amber-50 px-4 py-3 text-left dark:border-amber-900/40 dark:bg-amber-950/30"
            >
              <span className="text-sm font-semibold text-amber-900 dark:text-amber-300">
                Pending Reviews
              </span>
              <span className="rounded-full bg-amber-500 px-2 py-0.5 text-xs font-bold text-white">
                {pendingEdits.length}
              </span>
              <span className="ml-auto text-xs text-amber-600 dark:text-amber-400">
                {reviewExpanded ? '▲' : '▼'}
              </span>
            </button>

            {reviewExpanded && (
              <ul className="mt-2 space-y-2">
                {pendingEdits.map(edit => {
                  const isProcessing = processingIds.has(edit.edit_id)
                  const badge =
                    edit.edit_type === 'sold'
                      ? { label: 'Sold', cls: 'bg-blue-100 text-blue-700 dark:bg-blue-900 dark:text-blue-300' }
                      : edit.edit_type === 'partial_sold'
                      ? { label: 'Partial sold', cls: 'bg-orange-100 text-orange-700 dark:bg-orange-900 dark:text-orange-300' }
                      : edit.edit_type === 'damaged'
                      ? { label: 'Damaged', cls: 'bg-red-100 text-red-700 dark:bg-red-900 dark:text-red-300' }
                      : edit.edit_type === 'expired'
                      ? { label: 'Removed (expired)', cls: 'bg-neutral-200 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-400' }
                      : edit.edit_type === 'return_to_warehouse'
                      ? { label: 'Return to WH', cls: 'bg-purple-100 text-purple-700 dark:bg-purple-900 dark:text-purple-300' }
                      : { label: 'Stock update', cls: 'bg-neutral-100 text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400' }

                  return (
                    <li
                      key={edit.edit_id}
                      className="flex items-start gap-3 rounded-xl border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
                    >
                      <div className="min-w-0 flex-1">
                        <p className="text-sm font-bold">{edit.boonz_product_name}</p>
                        <p className="text-xs text-neutral-500">{edit.machine_name}</p>
                        <div className="mt-1 flex flex-wrap items-center gap-1.5">
                          <span className={`rounded-full px-2 py-0.5 text-xs font-medium ${badge.cls}`}>
                            {badge.label}
                          </span>
                          {edit.quantity_update !== null && (
                            <span className="text-xs text-neutral-500">Qty: {edit.quantity_update}</span>
                          )}
                        </div>
                        {edit.notes && (
                          <p className="mt-1 text-xs italic text-neutral-400">{edit.notes}</p>
                        )}
                        <p className="mt-1 text-xs text-neutral-400">
                          {edit.submitted_by_name ?? 'Driver'} · {formatTimeAgo(edit.created_at)}
                        </p>
                      </div>
                      <div className="flex shrink-0 flex-col gap-1.5">
                        <button
                          onClick={() => handleApprove(edit.edit_id, edit)}
                          disabled={isProcessing}
                          className="rounded-lg bg-green-600 px-3 py-1.5 text-xs font-semibold text-white hover:bg-green-700 disabled:opacity-40"
                        >
                          ✓ Approve
                        </button>
                        <button
                          onClick={() => handleReject(edit.edit_id)}
                          disabled={isProcessing}
                          className="rounded-lg border border-red-400 px-3 py-1.5 text-xs font-semibold text-red-600 hover:bg-red-50 disabled:opacity-40 dark:border-red-700 dark:text-red-400 dark:hover:bg-red-950/30"
                        >
                          ✗ Reject
                        </button>
                      </div>
                    </li>
                  )
                })}
              </ul>
            )}
          </div>
        )}

        {/* Search */}
        <div data-tour="inventory-filters">
        <input
          type="text"
          value={search}
          onChange={(e) => setSearch(e.target.value)}
          placeholder="Search products..."
          className="mb-3 w-full rounded-lg border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
        />

        {/* Status filter pills */}
        <div className="mb-3 flex gap-2">
          {([
            { label: 'All', value: 'All' as StatusFilter },
            { label: 'Active', value: 'Active' as StatusFilter },
            { label: 'Expired', value: 'Expired' as StatusFilter },
            { label: 'Inactive', value: 'Inactive' as StatusFilter },
          ]).map((s) => (
            <button
              key={s.value}
              onClick={() => setStatusFilter(s.value)}
              className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                statusFilter === s.value
                  ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                  : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
              }`}
            >
              {s.label}
            </button>
          ))}
        </div>

        {/* Expiry filter pills */}
        <div className="mb-3 flex gap-2 overflow-x-auto pb-1">
          {expiryFilters.map((f) => (
            <button
              key={f.value}
              onClick={() => setExpiryFilter(f.value)}
              className={`shrink-0 rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
                expiryFilter === f.value
                  ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                  : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
              }`}
            >
              {f.label}
            </button>
          ))}
        </div>

        {/* Hide empty toggle */}
        <div className="mb-3 flex gap-2">
          <button
            onClick={() => setHideEmpty(true)}
            className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
              hideEmpty
                ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
            }`}
          >
            Hide empty
          </button>
          <button
            onClick={() => setHideEmpty(false)}
            className={`rounded-full px-3 py-1.5 text-xs font-medium transition-colors ${
              !hideEmpty
                ? 'bg-neutral-900 text-white dark:bg-neutral-100 dark:text-neutral-900'
                : 'bg-neutral-100 text-neutral-600 hover:bg-neutral-200 dark:bg-neutral-800 dark:text-neutral-400 dark:hover:bg-neutral-700'
            }`}
          >
            Show all
          </button>
        </div>

        {/* Sort */}
        <div className="mb-3 flex items-center gap-2 text-xs text-neutral-500">
          <span>Sort:</span>
          {([
            { label: 'Expiry', value: 'expiry' as SortOption },
            { label: 'Location', value: 'location' as SortOption },
            { label: 'Name', value: 'name' as SortOption },
            { label: 'Qty High', value: 'qty_high' as SortOption },
            { label: 'Qty Low', value: 'qty_low' as SortOption },
          ]).map((s) => (
            <button
              key={s.value}
              onClick={() => setSortBy(s.value)}
              className={`rounded px-2 py-1 transition-colors ${
                sortBy === s.value
                  ? 'bg-neutral-200 font-medium text-neutral-900 dark:bg-neutral-700 dark:text-neutral-100'
                  : 'hover:bg-neutral-100 dark:hover:bg-neutral-800'
              }`}
            >
              {s.label}
            </button>
          ))}
        </div>

        {/* Group by */}
        <div className="mb-4 flex items-center gap-2 text-xs text-neutral-500">
          <span>Group:</span>
          {([
            { label: 'Category', value: 'category' as GroupBy },
            { label: 'Product', value: 'product' as GroupBy },
            { label: 'Location', value: 'location' as GroupBy },
            { label: 'None', value: 'none' as GroupBy },
          ]).map((g) => (
            <button
              key={g.value}
              onClick={() => setGroupBy(g.value)}
              className={`rounded px-2 py-1 transition-colors ${
                groupBy === g.value
                  ? 'bg-neutral-200 font-medium text-neutral-900 dark:bg-neutral-700 dark:text-neutral-100'
                  : 'hover:bg-neutral-100 dark:hover:bg-neutral-800'
              }`}
            >
              {g.label}
            </button>
          ))}
        </div>
        </div>

        {/* Results */}
        <div data-tour="inventory-list">
        {processed.length === 0 ? (
          <div className="flex flex-col items-center justify-center p-8 text-center">
            <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
              No items match this filter
            </p>
            <p className="mt-1 text-sm text-neutral-500">
              {search ? 'Try a different search term' : 'Try a different expiry range'}
            </p>
          </div>
        ) : groupBy !== 'none' ? (
          /* ── Grouped view ── */
          <div>
            {groups.map((group) => (
              <div key={group.key}>
                <SectionHeader
                  label={group.key}
                  itemCount={groupBy === 'product' ? group.items.length : group.items.length}
                  countLabel={groupBy === 'product' ? 'batches' : 'items'}
                  totalUnits={group.totalUnits}
                />
                <ul className="space-y-2">
                  {group.items.map((row) => {
                    const edit = controlEdits.get(row.wh_inventory_id)

                    if (controlMode && edit) {
                      return (
                        <li
                          key={row.wh_inventory_id}
                          className="rounded-lg border border-blue-200 bg-blue-50/50 p-4 dark:border-blue-900 dark:bg-blue-950/30"
                        >
                          <p className="truncate text-sm font-bold">{row.boonz_product_name}</p>
                          <div className="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs">
                            {groupBy !== 'location' && (
                              <span className="rounded-full bg-blue-100 px-2 py-0.5 font-medium text-blue-700 dark:bg-blue-900 dark:text-blue-300">
                                {row.wh_location || 'Unassigned'}
                              </span>
                            )}
                            {groupBy !== 'category' && row.product_category && (
                              <>
                                <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                                <span className="text-neutral-500">{row.product_category}</span>
                              </>
                            )}
                            <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                            <span className="text-neutral-400">{row.batch_id || 'No batch'}</span>
                          </div>
                          <div className="mt-3 grid grid-cols-3 gap-2">
                            <div>
                              <label className="mb-1 block text-xs text-neutral-500">Qty</label>
                              <input
                                type="number"
                                min={0}
                                value={edit.qty}
                                onChange={(e) =>
                                  updateControlEdit(row.wh_inventory_id, 'qty', parseInt(e.target.value, 10) || 0)
                                }
                                className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                              />
                            </div>
                            <div>
                              <label className="mb-1 block text-xs text-neutral-500">Location</label>
                              <input
                                type="text"
                                value={edit.location}
                                onChange={(e) =>
                                  updateControlEdit(row.wh_inventory_id, 'location', e.target.value)
                                }
                                className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                              />
                            </div>
                            <div>
                              <label className="mb-1 block text-xs text-neutral-500">Status</label>
                              <button
                                onClick={() =>
                                  updateControlEdit(
                                    row.wh_inventory_id,
                                    'status',
                                    edit.status === 'Active' ? 'Inactive' : 'Active'
                                  )
                                }
                                className={`w-full rounded px-2 py-1.5 text-sm font-medium ${
                                  edit.status === 'Active'
                                    ? 'bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                                    : 'bg-neutral-200 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-400'
                                }`}
                              >
                                {edit.status}
                              </button>
                            </div>
                          </div>
                        </li>
                      )
                    }

                    return (
                      <li key={row.wh_inventory_id}>
                        <Link
                          href={`/field/inventory/${row.wh_inventory_id}`}
                          className={`flex items-start rounded-lg border p-4 transition-colors ${
                            row.status === 'Expired'
                              ? 'border-l-4 border-l-red-400 border-neutral-200 bg-white hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900'
                              : 'border-neutral-200 bg-white hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900'
                          }`}
                        >
                          <div className="min-w-0 flex-1 pr-3">
                            {/* Line 1: location badge (product groupBy) or product name */}
                            {groupBy === 'product' ? (
                              <div className="flex flex-wrap items-center gap-1.5">
                                <span className="rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-700 dark:bg-blue-900 dark:text-blue-300">
                                  {row.wh_location || 'Unassigned'}
                                </span>
                                {row.product_category && (
                                  <span className="text-xs text-neutral-500">{row.product_category}</span>
                                )}
                              </div>
                            ) : (
                              <p className="truncate text-sm font-bold">{row.boonz_product_name}</p>
                            )}

                            {/* Line 2: meta badges */}
                            {groupBy !== 'product' && (
                              <div className="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs">
                                {groupBy !== 'location' && (
                                  <span className="rounded-full bg-blue-100 px-2 py-0.5 font-medium text-blue-700 dark:bg-blue-900 dark:text-blue-300">
                                    {row.wh_location || 'Unassigned'}
                                  </span>
                                )}
                                {groupBy !== 'category' && row.product_category && (
                                  <>
                                    <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                                    <span className="text-neutral-500">{row.product_category}</span>
                                  </>
                                )}
                                <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                                <span className="text-neutral-400">{row.batch_id || 'No batch'}</span>
                              </div>
                            )}

                            {/* Batch line for product groupBy */}
                            {groupBy === 'product' && (
                              <div className="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs">
                                <span className="text-neutral-400">{row.batch_id || 'No batch'}</span>
                              </div>
                            )}

                            {/* Expiry row */}
                            <div className="mt-1.5 flex flex-wrap items-center gap-2 text-xs">
                              <span className="text-neutral-500">{formatDate(row.expiration_date)}</span>
                              <ExpiryBadge expiryDate={row.expiration_date} />
                              {row.status === 'Expired' && (
                                <span className="rounded-full bg-red-100 px-2 py-0.5 font-medium text-red-700 dark:bg-red-900 dark:text-red-300">
                                  Expired
                                </span>
                              )}
                              {row.status === 'Inactive' && (
                                <span className="rounded-full bg-neutral-200 px-2 py-0.5 font-medium text-neutral-600 dark:bg-neutral-700 dark:text-neutral-400">
                                  Inactive
                                </span>
                              )}
                            </div>
                          </div>

                          <div className={`flex shrink-0 flex-col items-end ${getExpiryStyle(row.expiration_date).qtyColor}`}>
                            <p className="text-xl font-bold leading-none">{row.warehouse_stock}</p>
                            <p className="mt-0.5 text-xs opacity-60">units</p>
                          </div>
                        </Link>
                      </li>
                    )
                  })}
                </ul>
              </div>
            ))}
          </div>
        ) : (
          /* ── Flat view ── */
          <ul className="space-y-2">
            {processed.map((row) => {
              const edit = controlEdits.get(row.wh_inventory_id)

              if (controlMode && edit) {
                return (
                  <li
                    key={row.wh_inventory_id}
                    className="rounded-lg border border-blue-200 bg-blue-50/50 p-4 dark:border-blue-900 dark:bg-blue-950/30"
                  >
                    {/* Line 1: Product name */}
                    <p className="truncate text-sm font-bold">{row.boonz_product_name}</p>

                    {/* Line 2: Location badge + category + batch */}
                    <div className="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs">
                      <span className="rounded-full bg-blue-100 px-2 py-0.5 font-medium text-blue-700 dark:bg-blue-900 dark:text-blue-300">
                        {row.wh_location || 'Unassigned'}
                      </span>
                      {row.product_category && (
                        <>
                          <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                          <span className="text-neutral-500">{row.product_category}</span>
                        </>
                      )}
                      <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                      <span className="text-neutral-400">{row.batch_id || 'No batch'}</span>
                    </div>

                    {/* Editable fields */}
                    <div className="mt-3 grid grid-cols-3 gap-2">
                      <div>
                        <label className="mb-1 block text-xs text-neutral-500">Qty</label>
                        <input
                          type="number"
                          min={0}
                          value={edit.qty}
                          onChange={(e) =>
                            updateControlEdit(row.wh_inventory_id, 'qty', parseInt(e.target.value, 10) || 0)
                          }
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                        />
                      </div>
                      <div>
                        <label className="mb-1 block text-xs text-neutral-500">Location</label>
                        <input
                          type="text"
                          value={edit.location}
                          onChange={(e) =>
                            updateControlEdit(row.wh_inventory_id, 'location', e.target.value)
                          }
                          className="w-full rounded border border-neutral-300 px-2 py-1.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
                        />
                      </div>
                      <div>
                        <label className="mb-1 block text-xs text-neutral-500">Status</label>
                        <button
                          onClick={() =>
                            updateControlEdit(
                              row.wh_inventory_id,
                              'status',
                              edit.status === 'Active' ? 'Inactive' : 'Active'
                            )
                          }
                          className={`w-full rounded px-2 py-1.5 text-sm font-medium ${
                            edit.status === 'Active'
                              ? 'bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                              : 'bg-neutral-200 text-neutral-600 dark:bg-neutral-700 dark:text-neutral-400'
                          }`}
                        >
                          {edit.status}
                        </button>
                      </div>
                    </div>
                  </li>
                )
              }

              // Normal (non-control) row
              return (
                <li key={row.wh_inventory_id}>
                  <Link
                    href={`/field/inventory/${row.wh_inventory_id}`}
                    className={`flex items-start rounded-lg border p-4 transition-colors ${
                      row.status === 'Expired'
                        ? 'border-l-4 border-l-red-400 border-neutral-200 bg-white hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900'
                        : 'border-neutral-200 bg-white hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900'
                    }`}
                  >
                    {/* Left side */}
                    <div className="min-w-0 flex-1 pr-3">
                      {/* Line 1: Product name */}
                      <p className="truncate text-sm font-bold">{row.boonz_product_name}</p>

                      {/* Line 2: Location badge + category + batch */}
                      <div className="mt-0.5 flex flex-wrap items-center gap-1.5 text-xs">
                        <span className="rounded-full bg-blue-100 px-2 py-0.5 font-medium text-blue-700 dark:bg-blue-900 dark:text-blue-300">
                          {row.wh_location || 'Unassigned'}
                        </span>
                        {row.product_category && (
                          <>
                            <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                            <span className="text-neutral-500">{row.product_category}</span>
                          </>
                        )}
                        <span className="text-neutral-300 dark:text-neutral-600">&middot;</span>
                        <span className="text-neutral-400">{row.batch_id || 'No batch'}</span>
                      </div>

                      {/* Line 3: Expiry + badges */}
                      <div className="mt-1.5 flex flex-wrap items-center gap-2 text-xs">
                        <span className="text-neutral-500">{formatDate(row.expiration_date)}</span>
                        <ExpiryBadge expiryDate={row.expiration_date} />
                        {row.status === 'Expired' && (
                          <span className="rounded-full bg-red-100 px-2 py-0.5 font-medium text-red-700 dark:bg-red-900 dark:text-red-300">
                            Expired
                          </span>
                        )}
                        {row.status === 'Inactive' && (
                          <span className="rounded-full bg-neutral-200 px-2 py-0.5 font-medium text-neutral-600 dark:bg-neutral-700 dark:text-neutral-400">
                            Inactive
                          </span>
                        )}
                      </div>
                    </div>

                    {/* Right side: qty */}
                    <div className={`flex shrink-0 flex-col items-end ${getExpiryStyle(row.expiration_date).qtyColor}`}>
                      <p className="text-xl font-bold leading-none">{row.warehouse_stock}</p>
                      <p className="mt-0.5 text-xs opacity-60">units</p>
                    </div>
                  </Link>
                </li>
              )
            })}
          </ul>
        )}
        </div>
      </div>

      {/* Review toast */}
      {reviewToast && (
        <div className="fixed bottom-24 left-4 right-4 z-50 rounded-xl bg-green-100 px-4 py-3 text-center text-sm font-medium text-green-800 shadow-lg dark:bg-green-900 dark:text-green-200">
          {reviewToast}
        </div>
      )}

      {/* Floating "Complete control" button */}
      {controlMode && (
        <div className="fixed inset-x-0 bottom-20 z-30 px-4">
          <button
            onClick={completeControl}
            disabled={controlSaving}
            className="w-full rounded-xl bg-blue-600 py-3 text-sm font-semibold text-white shadow-lg hover:bg-blue-700 disabled:opacity-50"
          >
            {controlSaving ? 'Saving...' : 'Complete control'}
          </button>
        </div>
      )}
    </div>
  )
}
