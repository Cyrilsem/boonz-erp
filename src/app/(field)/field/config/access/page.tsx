'use client'

import { useEffect, useState, useCallback, useMemo } from 'react'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

// ─── Module definitions ───────────────────────────────────────────────────────

const MODULE_DISPLAY: Record<string, string> = {
  'packing':                'Packing',
  'receiving':              'Receiving',
  'inventory':              'Inventory',
  'orders':                 'Orders',
  'pod-inventory':          'Pod Inventory',
  'dispatching':            'Dispatching',
  'pickup':                 'Pickup',
  'trips':                  'Trips',
  'tasks':                  'Tasks',
  'config':                 'Config hub',
  'config.product-mapping': 'Product mapping',
  'config.pod-products':    'Pod products',
  'config.boonz-products':  'Boonz products',
  'config.machines':        'Machines',
  'config.suppliers':       'Suppliers',
}

const MODULE_GROUPS: { label: string; modules: string[] }[] = [
  { label: 'Warehouse', modules: ['packing', 'receiving', 'inventory', 'orders', 'pod-inventory'] },
  { label: 'Driver',    modules: ['dispatching', 'pickup', 'trips', 'tasks'] },
  { label: 'Config',    modules: ['config', 'config.product-mapping', 'config.pod-products', 'config.boonz-products', 'config.machines', 'config.suppliers'] },
]

const ALL_MODULES = MODULE_GROUPS.flatMap((g) => g.modules)

// Modules each role can meaningfully toggle
const ROLE_SCOPE: Record<string, string[]> = {
  operator_admin: ALL_MODULES,
  superadmin:     ALL_MODULES,
  manager:        ALL_MODULES,
  warehouse: [
    'packing', 'receiving', 'inventory', 'orders', 'pod-inventory',
    'config', 'config.product-mapping', 'config.pod-products',
    'config.boonz-products', 'config.machines', 'config.suppliers',
  ],
  field_staff: ['dispatching', 'pickup', 'trips', 'tasks', 'pod-inventory'],
}

function getDefault(role: string, mod: string): boolean {
  const warehouseMods = [
    'packing', 'receiving', 'inventory', 'orders', 'pod-inventory',
    'config', 'config.product-mapping', 'config.pod-products',
    'config.boonz-products', 'config.machines', 'config.suppliers',
  ]
  const driverMods = ['dispatching', 'pickup', 'trips', 'tasks', 'pod-inventory']

  if (role === 'operator_admin' || role === 'superadmin' || role === 'manager') return true
  if (role === 'warehouse') return warehouseMods.includes(mod)
  if (role === 'field_staff') return driverMods.includes(mod)
  return false
}

function isInScope(role: string, mod: string): boolean {
  return (ROLE_SCOPE[role] ?? []).includes(mod)
}

// operator_admin / superadmin rows are always read-only (can't lock out admin)
function isRowDisabled(role: string): boolean {
  return role === 'operator_admin' || role === 'superadmin'
}

// ─── Types ────────────────────────────────────────────────────────────────────

interface UserProfile {
  id: string
  full_name: string | null
  role: string
}

type PermMatrix = Record<string, Record<string, boolean>>

const ROLE_BADGE: Record<string, string> = {
  operator_admin: 'bg-purple-100 text-purple-700',
  superadmin:     'bg-purple-100 text-purple-700',
  manager:        'bg-blue-100 text-blue-700',
  warehouse:      'bg-amber-100 text-amber-700',
  field_staff:    'bg-green-100 text-green-700',
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function AccessManagementPage() {
  const router = useRouter()

  const [users, setUsers] = useState<UserProfile[]>([])
  const [matrix, setMatrix] = useState<PermMatrix>({})
  const [original, setOriginal] = useState<PermMatrix>({})
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [toast, setToast] = useState<string | null>(null)
  const [currentUserId, setCurrentUserId] = useState<string>('')

  const loadData = useCallback(async () => {
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()
    if (!user) { router.push('/login'); return }

    setCurrentUserId(user.id)

    const { data: profile } = await supabase
      .from('user_profiles')
      .select('role')
      .eq('id', user.id)
      .single()

    if (!profile || !['operator_admin', 'superadmin'].includes(profile.role as string)) {
      router.push('/field')
      return
    }

    const [{ data: allUsers }, { data: allPerms }] = await Promise.all([
      supabase
        .from('user_profiles')
        .select('id, full_name, role')
        .order('full_name'),
      supabase
        .from('module_permissions')
        .select('user_id, module, can_access'),
    ])

    // Build permission lookup: userId → module → can_access
    const permLookup = new Map<string, boolean>()
    for (const p of allPerms ?? []) {
      permLookup.set(`${p.user_id as string}::${p.module as string}`, p.can_access as boolean)
    }

    // Build matrix with DB values or role defaults
    const mat: PermMatrix = {}
    for (const u of allUsers ?? []) {
      mat[u.id] = {}
      for (const mod of ALL_MODULES) {
        const key = `${u.id}::${mod}`
        mat[u.id][mod] = permLookup.has(key)
          ? permLookup.get(key)!
          : getDefault(u.role as string, mod)
      }
    }

    setUsers((allUsers ?? []) as UserProfile[])
    setMatrix(mat)
    setOriginal(JSON.parse(JSON.stringify(mat)) as PermMatrix)
    setLoading(false)
  }, [router])

  useEffect(() => { loadData() }, [loadData])

  // Count changed cells vs original
  const changedCount = useMemo(() => {
    let n = 0
    for (const uid in matrix) {
      for (const mod of ALL_MODULES) {
        if (matrix[uid][mod] !== original[uid]?.[mod]) n++
      }
    }
    return n
  }, [matrix, original])

  function toggle(userId: string, mod: string) {
    setMatrix((prev) => ({
      ...prev,
      [userId]: { ...prev[userId], [mod]: !prev[userId][mod] },
    }))
  }

  async function handleSave() {
    setSaving(true)
    const supabase = createClient()

    const upserts: { user_id: string; module: string; can_access: boolean; granted_by: string }[] = []
    for (const uid in matrix) {
      for (const mod of ALL_MODULES) {
        if (matrix[uid][mod] !== original[uid]?.[mod]) {
          upserts.push({
            user_id: uid,
            module: mod,
            can_access: matrix[uid][mod],
            granted_by: currentUserId,
          })
        }
      }
    }

    if (upserts.length > 0) {
      await supabase
        .from('module_permissions')
        .upsert(upserts, { onConflict: 'user_id,module' })
    }

    setOriginal(JSON.parse(JSON.stringify(matrix)) as PermMatrix)
    setSaving(false)
    setToast('Permissions saved')
    setTimeout(() => setToast(null), 3000)
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Access Management" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading…</p>
        </div>
      </>
    )
  }

  return (
    <div className="pb-24">
      <FieldHeader title="Access Management" />

      <div className="px-4 py-4">
        <div className="mb-4 flex items-center justify-between">
          <div>
            <p className="text-sm text-neutral-500">Control which modules each user can access</p>
          </div>
          <button
            onClick={handleSave}
            disabled={saving || changedCount === 0}
            className="flex items-center gap-2 rounded-lg bg-neutral-900 px-4 py-2 text-sm font-medium text-white disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900"
          >
            {saving ? 'Saving…' : 'Save changes'}
            {changedCount > 0 && !saving && (
              <span className="rounded-full bg-blue-500 px-1.5 py-0.5 text-xs text-white">
                {changedCount}
              </span>
            )}
          </button>
        </div>

        <div className="overflow-x-auto rounded-xl border border-neutral-200 bg-white dark:border-neutral-800 dark:bg-neutral-950">
          <table className="min-w-[960px] w-full text-sm">
            <thead>
              {/* Group headers */}
              <tr className="border-b border-neutral-200 dark:border-neutral-800">
                <th className="w-44 py-3 pl-4 text-left text-xs font-semibold text-neutral-500" rowSpan={2}>
                  User
                </th>
                {MODULE_GROUPS.map((g) => (
                  <th
                    key={g.label}
                    colSpan={g.modules.length}
                    className="border-l border-neutral-100 py-2 text-center text-xs font-semibold uppercase tracking-wide text-neutral-400 dark:border-neutral-800"
                  >
                    {g.label}
                  </th>
                ))}
              </tr>
              {/* Module headers */}
              <tr className="border-b border-neutral-200 dark:border-neutral-800">
                {ALL_MODULES.map((mod, i) => {
                  const groupStart = MODULE_GROUPS.find((g) => g.modules[0] === mod)
                  return (
                    <th
                      key={mod}
                      className={`h-28 pb-2 align-bottom ${i > 0 ? 'border-l border-neutral-100 dark:border-neutral-800' : ''} ${groupStart ? 'border-l border-neutral-200 dark:border-neutral-700' : ''}`}
                    >
                      <div className="flex justify-center">
                        <span className="[writing-mode:vertical-rl] rotate-180 text-xs font-medium text-neutral-600 dark:text-neutral-400">
                          {MODULE_DISPLAY[mod]}
                        </span>
                      </div>
                    </th>
                  )
                })}
              </tr>
            </thead>

            <tbody>
              {users.map((u, uIdx) => {
                const rowDisabled = isRowDisabled(u.role)
                const badgeCls = ROLE_BADGE[u.role] ?? 'bg-neutral-100 text-neutral-600'
                return (
                  <tr
                    key={u.id}
                    className={`${uIdx > 0 ? 'border-t border-neutral-100 dark:border-neutral-800' : ''} ${rowDisabled ? 'opacity-60' : ''}`}
                  >
                    {/* User cell */}
                    <td className="py-3 pl-4 pr-2">
                      <p className="text-sm font-medium text-neutral-900 dark:text-neutral-100">
                        {u.full_name ?? '—'}
                      </p>
                      <span className={`mt-0.5 inline-block rounded-full px-2 py-0.5 text-xs font-medium ${badgeCls}`}>
                        {u.role}
                      </span>
                    </td>

                    {/* Module cells */}
                    {ALL_MODULES.map((mod, i) => {
                      const inScope = isInScope(u.role, mod)
                      const cellDisabled = rowDisabled || !inScope
                      const value = matrix[u.id]?.[mod] ?? false
                      const groupStart = MODULE_GROUPS.find((g) => g.modules[0] === mod)

                      return (
                        <td
                          key={mod}
                          className={`text-center ${i > 0 ? 'border-l border-neutral-100 dark:border-neutral-800' : ''} ${groupStart ? 'border-l border-neutral-200 dark:border-neutral-700' : ''}`}
                        >
                          {inScope ? (
                            <button
                              onClick={() => !cellDisabled && toggle(u.id, mod)}
                              disabled={cellDisabled}
                              title={cellDisabled && rowDisabled ? 'Admin access cannot be removed' : undefined}
                              className={`mx-auto flex h-7 w-10 items-center justify-center rounded-full text-xs font-semibold transition-colors ${
                                value
                                  ? 'bg-green-100 text-green-700 dark:bg-green-900/40 dark:text-green-400'
                                  : 'bg-neutral-100 text-neutral-400 dark:bg-neutral-800 dark:text-neutral-500'
                              } ${cellDisabled ? 'cursor-not-allowed' : 'cursor-pointer hover:opacity-80'}`}
                            >
                              {value ? '✓' : '—'}
                            </button>
                          ) : (
                            <span className="text-neutral-200 dark:text-neutral-700">—</span>
                          )}
                        </td>
                      )
                    })}
                  </tr>
                )
              })}
            </tbody>
          </table>
        </div>

        <p className="mt-3 text-xs text-neutral-400">
          Greyed-out cells are outside the user&apos;s role scope. Admin rows are read-only.
        </p>
      </div>

      {/* Toast */}
      {toast && (
        <div className="fixed bottom-24 left-4 right-4 z-50 rounded-xl bg-green-100 px-4 py-3 text-center text-sm font-medium text-green-800 shadow-lg dark:bg-green-900 dark:text-green-200">
          {toast}
        </div>
      )}
    </div>
  )
}
