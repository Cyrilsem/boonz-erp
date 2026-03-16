'use client'

import { useEffect, useState, useCallback } from 'react'
import { createClient } from '@/lib/supabase/client'

interface DriverTask {
  task_id: string
  po_id: string
  po_number: number
  supplier_name: string
  status: 'pending' | 'acknowledged' | 'collected' | 'cancelled'
  notes: string | null
  created_at: string
  acknowledged_at: string | null
  collected_at: string | null
}

function formatDateTime(isoStr: string): string {
  const d = new Date(isoStr)
  return (
    d.toLocaleDateString('en-US', { month: 'short', day: 'numeric' }) +
    ' at ' +
    d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' })
  )
}

function StatusBadge({ status }: { status: DriverTask['status'] }) {
  switch (status) {
    case 'pending':
      return (
        <span className="rounded-full bg-neutral-100 px-2 py-0.5 text-xs font-medium text-neutral-600 dark:bg-neutral-800 dark:text-neutral-400">
          Pending
        </span>
      )
    case 'acknowledged':
      return (
        <span className="rounded-full bg-blue-100 px-2 py-0.5 text-xs font-medium text-blue-700 dark:bg-blue-900 dark:text-blue-300">
          On my way
        </span>
      )
    case 'collected':
      return (
        <span className="rounded-full bg-green-100 px-2 py-0.5 text-xs font-medium text-green-700 dark:bg-green-900 dark:text-green-300">
          Collected ✓
        </span>
      )
    case 'cancelled':
      return (
        <span className="rounded-full bg-red-100 px-2 py-0.5 text-xs font-medium text-red-700 dark:bg-red-900 dark:text-red-300">
          Cancelled
        </span>
      )
  }
}

export default function TasksPage() {
  const [tasks, setTasks] = useState<DriverTask[]>([])
  const [loading, setLoading] = useState(true)
  const [updatingId, setUpdatingId] = useState<string | null>(null)

  const fetchTasks = useCallback(async () => {
    const supabase = createClient()

    const { data } = await supabase
      .from('driver_tasks')
      .select(`
        task_id,
        po_id,
        po_number,
        status,
        notes,
        created_at,
        acknowledged_at,
        collected_at,
        suppliers!inner(supplier_name)
      `)
      .order('created_at', { ascending: false })

    if (!data || data.length === 0) {
      setTasks([])
      setLoading(false)
      return
    }

    const mapped: DriverTask[] = data.map((row) => {
      const s = row.suppliers as unknown as { supplier_name: string }
      return {
        task_id: row.task_id,
        po_id: row.po_id,
        po_number: row.po_number,
        supplier_name: s.supplier_name,
        status: row.status as DriverTask['status'],
        notes: row.notes,
        created_at: row.created_at,
        acknowledged_at: row.acknowledged_at,
        collected_at: row.collected_at,
      }
    })

    setTasks(mapped)
    setLoading(false)
  }, [])

  useEffect(() => {
    fetchTasks()
  }, [fetchTasks])

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === 'visible') fetchTasks()
    }
    document.addEventListener('visibilitychange', handleVisibility)
    window.addEventListener('focus', fetchTasks)
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility)
      window.removeEventListener('focus', fetchTasks)
    }
  }, [fetchTasks])

  async function acknowledge(taskId: string) {
    setUpdatingId(taskId)
    const supabase = createClient()
    await supabase
      .from('driver_tasks')
      .update({ status: 'acknowledged', acknowledged_at: new Date().toISOString() })
      .eq('task_id', taskId)
    await fetchTasks()
    setUpdatingId(null)
  }

  async function markCollected(taskId: string) {
    setUpdatingId(taskId)
    const supabase = createClient()
    await supabase
      .from('driver_tasks')
      .update({ status: 'collected', collected_at: new Date().toISOString() })
      .eq('task_id', taskId)
    await fetchTasks()
    setUpdatingId(null)
  }

  const pending = tasks.filter(
    (t) => t.status === 'pending' || t.status === 'acknowledged'
  )
  const completed = tasks.filter(
    (t) => t.status === 'collected' || t.status === 'cancelled'
  )

  if (loading) {
    return (
      <div className="flex items-center justify-center p-8">
        <p className="text-neutral-500">Loading tasks…</p>
      </div>
    )
  }

  return (
    <div className="px-4 py-4 pb-24">
      <h1 className="mb-4 text-xl font-semibold">Tasks</h1>

      {/* Pending */}
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-500">
        Pending
      </h2>
      {pending.length === 0 ? (
        <p className="mb-6 text-sm text-neutral-400 text-center py-4">
          No tasks assigned yet
        </p>
      ) : (
        <ul className="mb-6 space-y-2">
          {pending.map((task) => (
            <li
              key={task.task_id}
              className="rounded-lg border border-neutral-200 bg-white p-4 dark:border-neutral-800 dark:bg-neutral-950"
            >
              <div className="flex items-start justify-between gap-2 mb-2">
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-semibold">{task.supplier_name}</p>
                  <p className="text-xs text-neutral-500">{task.po_id}</p>
                  <p className="text-xs text-neutral-400 mt-0.5">
                    {formatDateTime(task.created_at)}
                  </p>
                </div>
                <StatusBadge status={task.status} />
              </div>

              {task.notes && (
                <p className="text-sm text-neutral-600 dark:text-neutral-400 mb-3">
                  {task.notes}
                </p>
              )}

              <div className="flex gap-2">
                {task.status === 'pending' && (
                  <button
                    onClick={() => acknowledge(task.task_id)}
                    disabled={updatingId === task.task_id}
                    className="flex-1 rounded-lg border border-blue-300 py-2 text-xs font-medium text-blue-700 transition-colors hover:bg-blue-50 disabled:opacity-50 dark:border-blue-700 dark:text-blue-400 dark:hover:bg-blue-950"
                  >
                    {updatingId === task.task_id ? 'Updating…' : 'Acknowledge'}
                  </button>
                )}
                <button
                  onClick={() => markCollected(task.task_id)}
                  disabled={updatingId === task.task_id}
                  className="flex-1 rounded-lg bg-neutral-900 py-2 text-xs font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
                >
                  {updatingId === task.task_id ? 'Updating…' : 'Mark collected'}
                </button>
              </div>
            </li>
          ))}
        </ul>
      )}

      {/* Completed */}
      <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-500">
        Completed
      </h2>
      {completed.length === 0 ? (
        <p className="text-sm text-neutral-400 text-center py-4">
          No completed tasks
        </p>
      ) : (
        <ul className="space-y-2">
          {completed.map((task) => (
            <li
              key={task.task_id}
              className="rounded-lg border border-neutral-200 bg-white p-4 opacity-60 dark:border-neutral-800 dark:bg-neutral-950"
            >
              <div className="flex items-start justify-between gap-2">
                <div className="min-w-0 flex-1">
                  <p className="text-sm font-semibold">{task.supplier_name}</p>
                  <p className="text-xs text-neutral-500">{task.po_id}</p>
                  <p className="text-xs text-neutral-400 mt-0.5">
                    {formatDateTime(task.created_at)}
                  </p>
                  {task.notes && (
                    <p className="text-xs text-neutral-500 mt-1">{task.notes}</p>
                  )}
                </div>
                <StatusBadge status={task.status} />
              </div>
            </li>
          ))}
        </ul>
      )}
    </div>
  )
}
