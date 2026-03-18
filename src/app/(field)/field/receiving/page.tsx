'use client'

import { useEffect, useState, useCallback } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../components/field-header'

interface PendingPO {
  po_id: string
  supplier_name: string
  purchase_date: string
  line_count: number
}

function formatDate(dateStr: string): string {
  const d = new Date(dateStr + 'T00:00:00')
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' })
}

export default function ReceivingPage() {
  const [pos, setPos] = useState<PendingPO[]>([])
  const [loading, setLoading] = useState(true)

  const fetchPOs = useCallback(async () => {
    const supabase = createClient()

    const { data: lines } = await supabase
      .from('purchase_orders')
      .select('po_line_id, po_id, purchase_date, received_date, suppliers!inner(supplier_name)')
      .is('received_date', null)

    if (!lines || lines.length === 0) {
      setPos([])
      setLoading(false)
      return
    }

    const grouped = new Map<string, PendingPO>()

    for (const line of lines) {
      const s = line.suppliers as unknown as { supplier_name: string }
      const existing = grouped.get(line.po_id)
      if (existing) {
        existing.line_count += 1
      } else {
        grouped.set(line.po_id, {
          po_id: line.po_id,
          supplier_name: s.supplier_name,
          purchase_date: line.purchase_date,
          line_count: 1,
        })
      }
    }

    const sorted = Array.from(grouped.values()).sort((a, b) =>
      a.po_id.localeCompare(b.po_id)
    )
    setPos(sorted)
    setLoading(false)
  }, [])

  useEffect(() => {
    fetchPOs()
  }, [fetchPOs])

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === 'visible') fetchPOs()
    }
    document.addEventListener('visibilitychange', handleVisibility)
    window.addEventListener('focus', fetchPOs)
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility)
      window.removeEventListener('focus', fetchPOs)
    }
  }, [fetchPOs])

  if (loading) {
    return (
      <>
        <FieldHeader title="Receiving" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading deliveries…</p>
        </div>
      </>
    )
  }

  if (pos.length === 0) {
    return (
      <>
        <FieldHeader title="Receiving" />
        <div className="flex flex-col items-center justify-center p-8 text-center">
          <p className="text-lg font-medium text-neutral-600 dark:text-neutral-400">
            No pending deliveries
          </p>
        </div>
      </>
    )
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Receiving" />
      <ul className="space-y-2">
        {pos.map((po) => (
          <li key={po.po_id}>
            <Link
              href={`/field/receiving/${encodeURIComponent(po.po_id)}`}
              className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-4 transition-colors hover:bg-neutral-50 dark:border-neutral-800 dark:bg-neutral-950 dark:hover:bg-neutral-900"
            >
              <div className="flex-1 min-w-0">
                <p className="text-base font-semibold truncate">{po.po_id}</p>
                <p className="text-sm text-neutral-500 truncate">
                  {po.supplier_name}
                </p>
                <p className="text-xs text-neutral-400">
                  {formatDate(po.purchase_date)}
                </p>
              </div>
              <span className="shrink-0 rounded-full bg-neutral-100 px-2.5 py-0.5 text-xs font-medium dark:bg-neutral-800">
                {po.line_count} items
              </span>
              <span className="text-neutral-400">→</span>
            </Link>
          </li>
        ))}
      </ul>
    </div>
  )
}
