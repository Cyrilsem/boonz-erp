'use client'

import { useEffect, useState, useCallback } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'

type InventoryStatus = 'Active' | 'Inactive' | 'Expired' | 'Removed' | 'Reserved'

interface InventoryDetail {
  wh_inventory_id: string
  boonz_product_id: string
  boonz_product_name: string
  batch_id: string
  wh_location: string | null
  warehouse_stock: number
  expiration_date: string | null
  status: InventoryStatus
}

interface AuditEntry {
  audit_id: string
  old_qty: number
  new_qty: number
  delta: number
  reason: string | null
  audited_at: string
  full_name: string | null
}

function formatDate(dateStr: string | null): string {
  if (!dateStr) return '—'
  const d = new Date(dateStr + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
}

function formatAuditDate(isoStr: string): string {
  const d = new Date(isoStr)
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) +
    ' at ' +
    d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })
}

export default function InventoryDetailPage() {
  const params = useParams<{ inventoryId: string }>()
  const router = useRouter()
  const inventoryId = params.inventoryId

  const [item, setItem] = useState<InventoryDetail | null>(null)
  const [audits, setAudits] = useState<AuditEntry[]>([])
  const [loading, setLoading] = useState(true)

  // Edit mode
  const [editing, setEditing] = useState(false)
  const [editQty, setEditQty] = useState(0)
  const [editLocation, setEditLocation] = useState('')
  const [editReason, setEditReason] = useState('')
  const [saving, setSaving] = useState(false)
  const [saveError, setSaveError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)

  // Status toggle
  const [showStatusConfirm, setShowStatusConfirm] = useState(false)
  const [statusUpdating, setStatusUpdating] = useState(false)

  const fetchData = useCallback(async () => {
    const supabase = createClient()

    // Fetch inventory item
    const { data: invData } = await supabase
      .from('warehouse_inventory')
      .select(`
        wh_inventory_id,
        boonz_product_id,
        batch_id,
        wh_location,
        warehouse_stock,
        expiration_date,
        status,
        boonz_products!inner(boonz_product_name)
      `)
      .eq('wh_inventory_id', inventoryId)
      .single()

    if (invData) {
      const p = invData.boonz_products as unknown as { boonz_product_name: string }
      const detail: InventoryDetail = {
        wh_inventory_id: invData.wh_inventory_id,
        boonz_product_id: invData.boonz_product_id,
        boonz_product_name: p.boonz_product_name,
        batch_id: invData.batch_id ?? '',
        wh_location: invData.wh_location,
        warehouse_stock: invData.warehouse_stock ?? 0,
        expiration_date: invData.expiration_date,
        status: (invData.status as InventoryStatus) ?? 'Active',
      }
      setItem(detail)
      setEditQty(detail.warehouse_stock)
      setEditLocation(detail.wh_location ?? '')
    }

    // Fetch audit log
    const { data: auditData } = await supabase
      .from('inventory_audit_log')
      .select(`
        audit_id,
        old_qty,
        new_qty,
        delta,
        reason,
        audited_at,
        user_profiles!inventory_audit_log_adjusted_by_fkey(full_name)
      `)
      .eq('wh_inventory_id', inventoryId)
      .order('audited_at', { ascending: false })
      .limit(10)

    if (auditData) {
      const mapped: AuditEntry[] = auditData.map((a) => {
        const profile = a.user_profiles as unknown as { full_name: string | null } | null
        return {
          audit_id: a.audit_id,
          old_qty: a.old_qty ?? 0,
          new_qty: a.new_qty ?? 0,
          delta: a.delta ?? 0,
          reason: a.reason,
          audited_at: a.audited_at,
          full_name: profile?.full_name ?? null,
        }
      })
      setAudits(mapped)
    }

    setLoading(false)
  }, [inventoryId])

  useEffect(() => {
    fetchData()
  }, [fetchData])

  function enterEditMode() {
    if (!item) return
    setEditQty(item.warehouse_stock)
    setEditLocation(item.wh_location ?? '')
    setEditReason('')
    setSaveError(null)
    setSaved(false)
    setEditing(true)
  }

  async function handleSave() {
    if (!item) return
    if (!editReason.trim()) {
      setSaveError('Reason is required')
      return
    }

    setSaving(true)
    setSaveError(null)

    const supabase = createClient()
    const oldQty = item.warehouse_stock

    // 1. Update warehouse_inventory
    const { error: updateError } = await supabase
      .from('warehouse_inventory')
      .update({
        warehouse_stock: editQty,
        wh_location: editLocation.trim() || null,
      })
      .eq('wh_inventory_id', inventoryId)

    if (updateError) {
      setSaveError(`Save failed — try again`)
      setSaving(false)
      return
    }

    // 2. Insert audit log
    const { error: auditError } = await supabase
      .from('inventory_audit_log')
      .insert({
        wh_inventory_id: inventoryId,
        boonz_product_id: item.boonz_product_id,
        old_qty: oldQty,
        new_qty: editQty,
        reason: editReason.trim(),
      })

    if (auditError) {
      setSaveError(`Stock updated but audit log failed: ${auditError.message}`)
      setSaving(false)
      return
    }

    // Update local state
    setItem({
      ...item,
      warehouse_stock: editQty,
      wh_location: editLocation.trim() || null,
    })

    setSaving(false)
    setEditing(false)
    setSaved(true)

    // Refresh audit log
    fetchData()

    // Clear saved indicator after 2 seconds
    setTimeout(() => setSaved(false), 2000)
  }

  async function handleStatusToggle(newStatus: 'Active' | 'Inactive') {
    if (!item) return
    setStatusUpdating(true)
    setShowStatusConfirm(false)

    const supabase = createClient()
    const reason =
      newStatus === 'Inactive'
        ? 'Marked inactive — excluded from refill'
        : 'Reactivated — included in refill'

    const { error: updateError } = await supabase
      .from('warehouse_inventory')
      .update({ status: newStatus })
      .eq('wh_inventory_id', inventoryId)

    if (!updateError) {
      await supabase.from('inventory_audit_log').insert({
        wh_inventory_id: inventoryId,
        boonz_product_id: item.boonz_product_id,
        old_qty: item.warehouse_stock,
        new_qty: item.warehouse_stock,
        reason,
      })

      setItem({ ...item, status: newStatus })
      fetchData()
    }

    setStatusUpdating(false)
  }

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <p className="text-neutral-500">Loading…</p>
      </div>
    )
  }

  if (!item) {
    return (
      <div className="flex flex-col items-center justify-center p-8 text-center">
        <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
          Item not found
        </p>
        <button
          onClick={() => router.push('/field/inventory')}
          className="mt-4 text-sm text-neutral-500 hover:text-neutral-700"
        >
          ← Back to inventory
        </button>
      </div>
    )
  }

  return (
    <div className="px-4 py-4 pb-24">
      <button
        onClick={() => router.push('/field/inventory')}
        className="mb-3 text-sm text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
      >
        ← Back to inventory
      </button>

      {/* Header */}
      <div className="mb-4">
        <h1 className="text-xl font-semibold">{item.boonz_product_name}</h1>
        <p className="text-sm text-neutral-500 mt-1">
          {item.batch_id || 'No batch'} · {item.wh_location || 'No location'} · Expires {formatDate(item.expiration_date)}
        </p>
      </div>

      {/* Current stock */}
      <div className="mb-4 rounded-lg border border-neutral-200 bg-white p-6 text-center dark:border-neutral-800 dark:bg-neutral-950">
        <p className="text-xs uppercase tracking-wide text-neutral-500 mb-1">Current Stock</p>
        <p className="text-4xl font-bold">{item.warehouse_stock}</p>
        <p className="text-sm text-neutral-400 mt-1">units</p>
        {saved && (
          <p className="mt-2 text-sm font-medium text-green-600 dark:text-green-400">Saved ✓</p>
        )}
      </div>

      {/* Refill status */}
      <div className="mb-4 flex items-center justify-between rounded-lg border border-neutral-200 bg-white px-4 py-3 dark:border-neutral-800 dark:bg-neutral-950">
        <div>
          <p className="text-xs uppercase tracking-wide text-neutral-500 mb-1">Refill status</p>
          {item.status === 'Active' && (
            <span className="rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
              Active — included in refill
            </span>
          )}
          {item.status === 'Inactive' && (
            <span className="rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-900 dark:text-amber-200">
              Inactive — excluded from refill
            </span>
          )}
          {item.status === 'Expired' && (
            <span className="rounded-full bg-red-100 px-2.5 py-0.5 text-xs font-medium text-red-800 dark:bg-red-900 dark:text-red-200">
              Expired
            </span>
          )}
          {item.status === 'Removed' && (
            <span className="rounded-full bg-neutral-100 px-2.5 py-0.5 text-xs font-medium text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
              Removed
            </span>
          )}
          {item.status === 'Reserved' && (
            <span className="rounded-full bg-blue-100 px-2.5 py-0.5 text-xs font-medium text-blue-800 dark:bg-blue-900 dark:text-blue-200">
              Reserved
            </span>
          )}
        </div>
        {item.status === 'Active' && (
          <button
            onClick={() => setShowStatusConfirm(true)}
            disabled={statusUpdating}
            className="shrink-0 rounded-lg border border-amber-300 px-3 py-1.5 text-xs font-medium text-amber-700 transition-colors hover:bg-amber-50 disabled:opacity-50 dark:border-amber-700 dark:text-amber-400 dark:hover:bg-amber-950"
          >
            Mark as inactive
          </button>
        )}
        {item.status === 'Inactive' && (
          <button
            onClick={() => handleStatusToggle('Active')}
            disabled={statusUpdating}
            className="shrink-0 rounded-lg border border-green-300 px-3 py-1.5 text-xs font-medium text-green-700 transition-colors hover:bg-green-50 disabled:opacity-50 dark:border-green-700 dark:text-green-400 dark:hover:bg-green-950"
          >
            {statusUpdating ? 'Updating…' : 'Reactivate'}
          </button>
        )}
      </div>

      {/* Inactive confirm dialog */}
      {showStatusConfirm && (
        <div className="fixed inset-0 z-50 flex items-center justify-center bg-black/50 px-6">
          <div className="w-full max-w-sm rounded-xl bg-white p-6 shadow-xl dark:bg-neutral-900">
            <h2 className="text-lg font-semibold mb-2">
              Mark {item.boonz_product_name} as inactive?
            </h2>
            <p className="text-sm text-neutral-600 dark:text-neutral-400">
              This will exclude it from future refill plans.
              Stock will remain tracked in the warehouse.
            </p>
            <div className="mt-5 flex gap-3">
              <button
                onClick={() => setShowStatusConfirm(false)}
                className="flex-1 rounded-lg border border-neutral-300 py-2.5 text-sm font-medium text-neutral-600 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:text-neutral-400 dark:hover:bg-neutral-800"
              >
                Cancel
              </button>
              <button
                onClick={() => handleStatusToggle('Inactive')}
                disabled={statusUpdating}
                className="flex-1 rounded-lg bg-amber-600 py-2.5 text-sm font-medium text-white transition-colors hover:bg-amber-700 disabled:opacity-50"
              >
                {statusUpdating ? 'Updating…' : 'Confirm'}
              </button>
            </div>
          </div>
        </div>
      )}

      {/* Edit section */}
      {!editing ? (
        <button
          onClick={enterEditMode}
          className="mb-6 w-full rounded-lg border border-neutral-300 py-2.5 text-sm font-medium text-neutral-700 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:text-neutral-300 dark:hover:bg-neutral-900"
        >
          Edit stock
        </button>
      ) : (
        <div className="mb-6 rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950">
          <h2 className="mb-3 text-sm font-semibold">Adjust Stock</h2>

          <div className="space-y-3">
            <div>
              <label className="block text-xs text-neutral-500 mb-0.5">Quantity</label>
              <input
                type="number"
                min={0}
                value={editQty}
                onChange={(e) => setEditQty(parseFloat(e.target.value) || 0)}
                className="w-full rounded border border-neutral-300 px-3 py-2 text-sm dark:border-neutral-600 dark:bg-neutral-900"
              />
            </div>

            <div>
              <label className="block text-xs text-neutral-500 mb-0.5">Location</label>
              <input
                type="text"
                value={editLocation}
                onChange={(e) => setEditLocation(e.target.value)}
                placeholder="e.g. A-01"
                className="w-full rounded border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
              />
            </div>

            <div>
              <label className="block text-xs text-neutral-500 mb-0.5">
                Reason <span className="text-red-500">*</span>
              </label>
              <input
                type="text"
                value={editReason}
                onChange={(e) => setEditReason(e.target.value)}
                placeholder="Reason for adjustment (e.g. Audit count, Damaged, Consumed)"
                className="w-full rounded border border-neutral-300 px-3 py-2 text-sm placeholder:text-neutral-400 dark:border-neutral-600 dark:bg-neutral-900"
              />
            </div>
          </div>

          {saveError && (
            <p className="mt-2 text-sm text-red-600 dark:text-red-400">{saveError}</p>
          )}

          <div className="mt-4 flex gap-2">
            <button
              onClick={() => setEditing(false)}
              className="flex-1 rounded-lg border border-neutral-300 py-2.5 text-sm font-medium text-neutral-600 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:text-neutral-400 dark:hover:bg-neutral-900"
            >
              Cancel
            </button>
            <button
              onClick={handleSave}
              disabled={saving}
              className="flex-1 rounded-lg bg-neutral-900 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
            >
              {saving ? 'Saving…' : 'Save adjustment'}
            </button>
          </div>
        </div>
      )}

      {/* Audit history */}
      <div>
        <h2 className="mb-3 text-sm font-semibold uppercase tracking-wide text-neutral-500">
          Audit History
        </h2>

        {audits.length === 0 ? (
          <p className="text-sm text-neutral-400 text-center py-6">
            No adjustments recorded yet
          </p>
        ) : (
          <ul className="space-y-2">
            {audits.map((audit) => (
              <li
                key={audit.audit_id}
                className="rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
              >
                <div className="flex items-start justify-between gap-2">
                  <div className="min-w-0 flex-1">
                    <p className="text-xs text-neutral-400">
                      {formatAuditDate(audit.audited_at)}
                    </p>
                    <p className="text-sm mt-0.5">
                      {audit.old_qty} → {audit.new_qty}
                    </p>
                    {audit.reason && (
                      <p className="text-xs text-neutral-500 mt-0.5">{audit.reason}</p>
                    )}
                    {audit.full_name && (
                      <p className="text-xs text-neutral-400 mt-0.5">by {audit.full_name}</p>
                    )}
                  </div>
                  <span
                    className={`shrink-0 text-sm font-semibold ${
                      audit.delta >= 0
                        ? 'text-green-600 dark:text-green-400'
                        : 'text-red-600 dark:text-red-400'
                    }`}
                  >
                    {audit.delta >= 0 ? `+${audit.delta}` : `${audit.delta}`}
                  </span>
                </div>
              </li>
            ))}
          </ul>
        )}
      </div>
    </div>
  )
}
