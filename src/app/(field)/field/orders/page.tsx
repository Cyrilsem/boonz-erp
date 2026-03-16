'use client'

import { useEffect, useState, useCallback } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'

interface POGroup {
  po_id: string
  supplier_name: string
  purchase_date: string
  line_count: number
  total_ordered: number
  received_date: string | null
}

type TabOption = 'pending' | 'all'

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
}

export default function OrdersPage() {
  const [orders, setOrders] = useState<POGroup[]>([])
  const [loading, setLoading] = useState(true)
  const [tab, setTab] = useState<TabOption>('pending')

  const fetchOrders = useCallback(async () => {
    const supabase = createClient()

    const query = supabase
      .from('purchase_orders')
      .select(`
        po_line_id,
        po_id,
        purchase_date,
        ordered_qty,
        received_date,
        suppliers!inner(supplier_name)
      `)
      .order('purchase_date', { ascending: false })

    const { data: lines } = await query

    if (!lines || lines.length === 0) {
      setOrders([])
      setLoading(false)
      return
    }

    const grouped = new Map<string, POGroup>()
    for (const line of lines) {
      const s = line.suppliers as unknown as { supplier_name: string }
      const existing = grouped.get(line.po_id)
      if (existing) {
        existing.line_count += 1
        existing.total_ordered += line.ordered_qty ?? 0
        // PO is received only if ALL lines are received
        if (!line.received_date) {
          existing.received_date = null
        }
      } else {
        grouped.set(line.po_id, {
          po_id: line.po_id,
          supplier_name: s.supplier_name,
          purchase_date: line.purchase_date,
          line_count: 1,
          total_ordered: line.ordered_qty ?? 0,
          received_date: line.received_date,
        })
      }
    }

    const result = Array.from(grouped.values()).sort((a, b) =>
      b.purchase_date.localeCompare(a.purchase_date)
    )

    setOrders(result)
    setLoading(false)
  }, [])

  useEffect(() => {
    fetchOrders()
  }, [fetchOrders])

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === 'visible') fetchOrders()
    }
    document.addEventListener('visibilitychange', handleVisibility)
    window.addEventListener('focus', fetchOrders)
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility)
      window.removeEventListener('focus', fetchOrders)
    }
  }, [fetchOrders])

  const filtered = tab === 'pending'
    ? orders.filter((o) => !o.received_date)
    : orders.slice(0, 30)

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <p className="text-neutral-500">Loading orders…</p>
      </div>
    )
  }

  return (
    <div className="px-4 py-4 pb-24">
      <h1 className="mb-3 text-xl font-semibold">Purchase Orders</h1>

      {/* Tabs */}
      <div className="mb-4 flex border-b border-neutral-200 dark:border-neutral-800">
        {([
          { label: 'Pending', value: 'pending' as TabOption },
          { label: 'All orders', value: 'all' as TabOption },
        ]).map((t) => (
          <button
            key={t.value}
            onClick={() => setTab(t.value)}
            className={`flex-1 py-2.5 text-sm font-medium transition-colors ${
              tab === t.value
                ? 'border-b-2 border-neutral-900 text-neutral-900 dark:border-neutral-100 dark:text-neutral-100'
                : 'text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300'
            }`}
          >
            {t.label}
          </button>
        ))}
      </div>

      {/* Orders */}
      {filtered.length === 0 ? (
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            {tab === 'pending' ? 'No pending orders' : 'No orders found'}
          </p>
          <p className="mt-1 text-sm text-neutral-500">
            {tab === 'pending' ? 'All purchase orders have been received' : 'Create your first PO'}
          </p>
        </div>
      ) : (
        <ul className="space-y-2">
          {filtered.map((order) => (
            <li
              key={order.po_id}
              className="rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
            >
              <div className="flex items-start justify-between gap-3">
                <div className="min-w-0 flex-1">
                  <p className="text-base font-semibold truncate">{order.po_id}</p>
                  <p className="text-sm text-neutral-500">{order.supplier_name}</p>
                  <p className="text-xs text-neutral-400 mt-0.5">
                    {formatDate(order.purchase_date)} · {order.line_count} {order.line_count === 1 ? 'line' : 'lines'} · {order.total_ordered} units
                  </p>
                </div>
                <div className="shrink-0 flex flex-col items-end gap-2">
                  {order.received_date ? (
                    <span className="rounded-full bg-green-100 px-2.5 py-0.5 text-xs font-medium text-green-800 dark:bg-green-900 dark:text-green-200">
                      Received {formatDate(order.received_date)}
                    </span>
                  ) : (
                    <>
                      <span className="rounded-full bg-amber-100 px-2.5 py-0.5 text-xs font-medium text-amber-800 dark:bg-amber-900 dark:text-amber-200">
                        Pending
                      </span>
                      <Link
                        href={`/field/receiving/${encodeURIComponent(order.po_id)}`}
                        className="rounded-lg bg-neutral-900 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                      >
                        Receive
                      </Link>
                    </>
                  )}
                </div>
              </div>
            </li>
          ))}
        </ul>
      )}

      {/* FAB */}
      <Link
        href="/field/orders/new"
        className="fixed bottom-20 right-4 flex h-14 w-14 items-center justify-center rounded-full bg-neutral-900 text-2xl text-white shadow-lg transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
      >
        +
      </Link>
    </div>
  )
}
