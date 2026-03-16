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

interface POLineDetail {
  boonz_product_name: string
  ordered_qty: number
  price_per_unit_aed: number | null
  total_price_aed: number | null
  expiry_date: string | null
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
  const [expandedPoId, setExpandedPoId] = useState<string | null>(null)
  const [expandedLines, setExpandedLines] = useState<POLineDetail[]>([])
  const [expandLoading, setExpandLoading] = useState(false)

  const fetchOrders = useCallback(async () => {
    const supabase = createClient()

    const { data: lines } = await supabase
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

  async function toggleExpand(poId: string) {
    if (expandedPoId === poId) {
      setExpandedPoId(null)
      setExpandedLines([])
      return
    }

    setExpandedPoId(poId)
    setExpandedLines([])
    setExpandLoading(true)

    const supabase = createClient()
    const { data } = await supabase
      .from('purchase_orders')
      .select(`
        ordered_qty,
        price_per_unit_aed,
        total_price_aed,
        expiry_date,
        boonz_products!inner(boonz_product_name)
      `)
      .eq('po_id', poId)

    if (data) {
      const mapped: POLineDetail[] = data.map((row) => {
        const p = row.boonz_products as unknown as { boonz_product_name: string }
        return {
          boonz_product_name: p.boonz_product_name,
          ordered_qty: row.ordered_qty ?? 0,
          price_per_unit_aed: row.price_per_unit_aed,
          total_price_aed: row.total_price_aed,
          expiry_date: row.expiry_date,
        }
      })
      setExpandedLines(mapped)
    }

    setExpandLoading(false)
  }

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
            onClick={() => { setTab(t.value); setExpandedPoId(null) }}
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
          {filtered.map((order) => {
            const isExpanded = expandedPoId === order.po_id && tab === 'all'

            return (
              <li key={order.po_id}>
                <div
                  className={`rounded-lg border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950 ${
                    tab === 'all' ? 'cursor-pointer' : ''
                  }`}
                  onClick={tab === 'all' ? () => toggleExpand(order.po_id) : undefined}
                >
                  <div className="flex items-start justify-between gap-3 p-4">
                    <div className="min-w-0 flex-1">
                      <p className="text-base font-semibold truncate">{order.po_id}</p>
                      <p className="text-sm text-neutral-500">{order.supplier_name}</p>
                      <p className="text-xs text-neutral-400 mt-0.5">
                        {formatDate(order.purchase_date)} · {order.line_count}{' '}
                        {order.line_count === 1 ? 'line' : 'lines'} · {order.total_ordered} units
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
                          {tab === 'pending' && (
                            <Link
                              href={`/field/receiving/${encodeURIComponent(order.po_id)}`}
                              className="rounded-lg bg-neutral-900 px-3 py-1.5 text-xs font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                            >
                              Receive
                            </Link>
                          )}
                        </>
                      )}
                      {tab === 'all' && (
                        <span className="text-xs text-neutral-400">
                          {isExpanded ? '▲' : '▼'}
                        </span>
                      )}
                    </div>
                  </div>

                  {/* Expanded detail */}
                  <div
                    className="overflow-hidden transition-all duration-200"
                    style={{ maxHeight: isExpanded ? '600px' : '0px' }}
                  >
                    <div className="border-t border-neutral-100 px-4 pb-4 pt-3 dark:border-neutral-800">
                      {expandLoading ? (
                        <div className="space-y-2">
                          {[1, 2, 3].map((i) => (
                            <div
                              key={i}
                              className="h-6 animate-pulse rounded bg-neutral-100 dark:bg-neutral-800"
                            />
                          ))}
                        </div>
                      ) : (
                        <>
                          <table className="w-full text-xs">
                            <thead>
                              <tr className="text-left text-neutral-400">
                                <th className="pb-1 font-medium">Product</th>
                                <th className="pb-1 font-medium text-right">Qty</th>
                                <th className="pb-1 font-medium text-right">Price</th>
                                <th className="pb-1 font-medium text-right">Total</th>
                                <th className="pb-1 font-medium text-right">Expiry</th>
                              </tr>
                            </thead>
                            <tbody>
                              {expandedLines.map((line, idx) => (
                                <tr
                                  key={idx}
                                  className="border-t border-neutral-50 dark:border-neutral-900"
                                >
                                  <td className="py-1.5 pr-2 truncate max-w-[120px]">
                                    {line.boonz_product_name}
                                  </td>
                                  <td className="py-1.5 text-right">{line.ordered_qty}</td>
                                  <td className="py-1.5 text-right">
                                    {line.price_per_unit_aed != null
                                      ? `${line.price_per_unit_aed.toFixed(2)}`
                                      : '—'}
                                  </td>
                                  <td className="py-1.5 text-right">
                                    {line.total_price_aed != null
                                      ? `${line.total_price_aed.toFixed(2)}`
                                      : '—'}
                                  </td>
                                  <td className="py-1.5 text-right text-neutral-400">
                                    {line.expiry_date
                                      ? formatDate(line.expiry_date)
                                      : '—'}
                                  </td>
                                </tr>
                              ))}
                            </tbody>
                            <tfoot>
                              <tr className="border-t border-neutral-200 font-medium dark:border-neutral-700">
                                <td className="pt-1.5" colSpan={3}>
                                  Total
                                </td>
                                <td className="pt-1.5 text-right">
                                  {expandedLines
                                    .reduce((sum, l) => sum + (l.total_price_aed ?? 0), 0)
                                    .toFixed(2)}{' '}
                                  AED
                                </td>
                                <td />
                              </tr>
                            </tfoot>
                          </table>

                          {!order.received_date && (
                            <Link
                              href={`/field/receiving/${encodeURIComponent(order.po_id)}`}
                              onClick={(e) => e.stopPropagation()}
                              className="mt-3 block w-full rounded-lg bg-neutral-900 py-2 text-center text-xs font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                            >
                              Receive
                            </Link>
                          )}
                        </>
                      )}
                    </div>
                  </div>
                </div>
              </li>
            )
          })}
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
