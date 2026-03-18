'use client'

import { useEffect, useState, useCallback } from 'react'
import Link from 'next/link'
import { useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'

type Role = 'warehouse' | 'field_staff'

interface UserInfo {
  full_name: string | null
  role: Role
}

interface WarehouseKpis {
  machinesToday: number
  totalLines: number
  packedLines: number
  pickedUpLines: number
  dispatchedLines: number
  expired: number
  expiring3: number
  expiring7: number
  expiring30: number
  openPOs: number
  receivedToday: number
  activeItems: number
  expiringWeek: number
  lastControlDays: number | null // null = never
}

interface DriverKpis {
  stopsToday: number
  pickupReady: number
  toDispatch: number
  openTasks: number
}

interface PodExpiryKpis {
  expired: number
  expiring3: number
  expiring7: number
  expiring30: number
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function getGreeting(): string {
  const h = new Date().getHours()
  if (h < 12) return 'Good morning'
  if (h < 17) return 'Good afternoon'
  return 'Good evening'
}

function formatToday(): string {
  return new Date().toLocaleDateString('en-US', {
    weekday: 'long',
    day: 'numeric',
    month: 'long',
    year: 'numeric',
  })
}

function todayISO(): string {
  return new Date().toISOString().split('T')[0]
}

function addDays(dateStr: string, days: number): string {
  const d = new Date(dateStr + 'T00:00:00')
  d.setDate(d.getDate() + days)
  return d.toISOString().split('T')[0]
}

// ─── KPI card style ───────────────────────────────────────────────────────────

interface KpiCardStyle {
  bg: string
  border: string
  text: string
  sub: string
}

function kpiCardStyle(count: number, urgency: 'critical' | 'high' | 'medium' | 'low'): KpiCardStyle {
  if (count === 0) return { bg: 'bg-green-50', border: 'border-green-200', text: 'text-green-700', sub: 'text-green-500' }
  const map: Record<typeof urgency, KpiCardStyle> = {
    critical: { bg: 'bg-red-50',    border: 'border-red-200',    text: 'text-red-700',    sub: 'text-red-500'    },
    high:     { bg: 'bg-red-50',    border: 'border-red-200',    text: 'text-red-600',    sub: 'text-red-400'    },
    medium:   { bg: 'bg-yellow-50', border: 'border-yellow-200', text: 'text-yellow-700', sub: 'text-yellow-500' },
    low:      { bg: 'bg-lime-50',   border: 'border-lime-200',   text: 'text-lime-700',   sub: 'text-lime-500'   },
  }
  return map[urgency]
}

// ─── Section card ─────────────────────────────────────────────────────────────

function SectionCard({
  title,
  linkTo,
  rightContent,
  children,
}: {
  title: string
  linkTo?: string
  rightContent?: React.ReactNode
  children: React.ReactNode
}) {
  return (
    <section className="mb-4 rounded-2xl border border-gray-100 bg-white p-4 shadow-sm">
      <div className="mb-3 flex items-center justify-between">
        <h2 className="text-sm font-bold uppercase tracking-wide text-gray-500">{title}</h2>
        <div className="flex items-center gap-2">
          {rightContent}
          {linkTo && (
            <Link href={linkTo} className="text-xs font-medium text-blue-500">
              View →
            </Link>
          )}
        </div>
      </div>
      {children}
    </section>
  )
}

// ─── Stat card ────────────────────────────────────────────────────────────────

function StatCard({
  value,
  label,
  subLabel,
  cardStyle,
  href,
}: {
  value: string | number
  label: string
  subLabel?: string
  cardStyle: KpiCardStyle
  href: string
}) {
  return (
    <Link
      href={href}
      className={`rounded-xl border p-3 transition-opacity hover:opacity-80 ${cardStyle.bg} ${cardStyle.border}`}
    >
      <p className={`text-2xl font-bold ${cardStyle.text}`}>{value}</p>
      <p className={`mt-0.5 text-xs font-medium ${cardStyle.text}`}>{label}</p>
      {subLabel && <p className={`mt-0.5 text-xs ${cardStyle.sub}`}>{subLabel}</p>}
    </Link>
  )
}

// ─── Pct card style helper ────────────────────────────────────────────────────

function pctCardStyle(pct: number, hasLines: boolean): KpiCardStyle {
  if (!hasLines) return kpiCardStyle(0, 'low')
  if (pct === 100) return kpiCardStyle(0, 'low')
  if (pct > 0) return kpiCardStyle(1, 'medium')
  return kpiCardStyle(1, 'high')
}

// ─── Skeleton ─────────────────────────────────────────────────────────────────

function Skeleton() {
  return (
    <div className="px-4 py-4 pb-24 space-y-4 animate-pulse">
      <div className="h-7 w-48 rounded bg-neutral-200 dark:bg-neutral-800" />
      <div className="h-4 w-36 rounded bg-neutral-200 dark:bg-neutral-800" />
      {[1, 2, 3].map((i) => (
        <div key={i} className="h-40 rounded-2xl bg-neutral-200 dark:bg-neutral-800" />
      ))}
    </div>
  )
}

// ─── Warehouse Home ───────────────────────────────────────────────────────────

function WarehouseHome({
  user,
  kpis,
  podKpis,
}: {
  user: UserInfo
  kpis: WarehouseKpis
  podKpis: PodExpiryKpis
}) {
  const packedPct    = kpis.totalLines > 0 ? Math.round((kpis.packedLines    / kpis.totalLines) * 100) : 0
  const pickedUpPct  = kpis.totalLines > 0 ? Math.round((kpis.pickedUpLines  / kpis.totalLines) * 100) : 0
  const dispatchedPct = kpis.totalLines > 0 ? Math.round((kpis.dispatchedLines / kpis.totalLines) * 100) : 0
  const hasLines = kpis.totalLines > 0

  const lastControlLabel = kpis.lastControlDays === null
    ? 'Last control: Never'
    : kpis.lastControlDays === 0
    ? 'Last control: Today'
    : `Last control: ${kpis.lastControlDays}d ago`

  const lastControlColor = kpis.lastControlDays === null || kpis.lastControlDays > 30
    ? 'text-red-500'
    : kpis.lastControlDays > 7
    ? 'text-yellow-500'
    : 'text-green-500'

  return (
    <div className="px-4 py-4 pb-24">
      <h1 className="text-xl font-semibold">
        {getGreeting()}, {user.full_name ?? 'Warehouse'}
      </h1>
      <p className="mb-4 text-sm text-neutral-500">{formatToday()}</p>

      {/* ── Section 1: Daily Refills ── */}
      <SectionCard title="Daily Refills" linkTo="/field/packing">
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={kpis.machinesToday}
            label="To refill today"
            cardStyle={kpiCardStyle(kpis.machinesToday > 0 ? 1 : 0, 'low')}
            href="/field/packing"
          />
          <StatCard
            value={`${packedPct}%`}
            label="Packing complete"
            subLabel={`${kpis.packedLines} of ${kpis.totalLines} lines`}
            cardStyle={pctCardStyle(packedPct, hasLines)}
            href="/field/packing"
          />
          <StatCard
            value={`${pickedUpPct}%`}
            label="Picked up"
            subLabel={`${kpis.pickedUpLines} of ${kpis.totalLines} lines`}
            cardStyle={pctCardStyle(pickedUpPct, hasLines)}
            href="/field/pickup"
          />
          <StatCard
            value={`${dispatchedPct}%`}
            label="Dispatched"
            subLabel={`${kpis.dispatchedLines} of ${kpis.totalLines} lines`}
            cardStyle={pctCardStyle(dispatchedPct, hasLines)}
            href="/field/dispatching"
          />
        </div>
      </SectionCard>

      {/* ── Section 2: Procurement ── */}
      <SectionCard title="Procurement" linkTo="/field/orders">
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={kpis.openPOs}
            label="Open orders"
            subLabel="Pending delivery"
            cardStyle={kpiCardStyle(kpis.openPOs, 'medium')}
            href="/field/orders"
          />
          <StatCard
            value={kpis.receivedToday}
            label="Received today"
            cardStyle={kpiCardStyle(0, 'low')}
            href="/field/receiving"
          />
          <Link
            href="/field/orders/new"
            className="col-span-2 flex items-center justify-center gap-2 rounded-xl border-2 border-dashed border-blue-200 bg-blue-50 py-3 text-sm font-medium text-blue-600 transition-colors hover:bg-blue-100"
          >
            + New Purchase Order
          </Link>
        </div>
      </SectionCard>

      {/* ── Section 3: Inventory ── */}
      <SectionCard
        title="Inventory"
        linkTo="/field/inventory"
        rightContent={
          <span className={`text-xs font-medium ${lastControlColor}`}>{lastControlLabel}</span>
        }
      >
        <p className="mb-2 mt-1 text-xs text-gray-400">Warehouse stock</p>
        <div className="grid grid-cols-2 gap-3">
          <StatCard value={kpis.expired}   label="Expired"   cardStyle={kpiCardStyle(kpis.expired,   'critical')} href="/field/inventory" />
          <StatCard value={kpis.expiring3} label="< 3 days"  cardStyle={kpiCardStyle(kpis.expiring3, 'high')}     href="/field/inventory" />
          <StatCard value={kpis.expiring7} label="< 7 days"  cardStyle={kpiCardStyle(kpis.expiring7, 'medium')}   href="/field/inventory" />
          <StatCard value={kpis.expiring30} label="< 30 days" cardStyle={kpiCardStyle(kpis.expiring30,'low')}     href="/field/inventory" />
        </div>

        <p className="mb-2 mt-4 text-xs text-gray-400">Machine stock</p>
        <div className="grid grid-cols-2 gap-3">
          <StatCard value={podKpis.expired}    label="Expired"   cardStyle={kpiCardStyle(podKpis.expired,   'critical')} href="/field/pod-inventory" />
          <StatCard value={podKpis.expiring3}  label="< 3 days"  cardStyle={kpiCardStyle(podKpis.expiring3, 'high')}     href="/field/pod-inventory" />
          <StatCard value={podKpis.expiring7}  label="< 7 days"  cardStyle={kpiCardStyle(podKpis.expiring7, 'medium')}   href="/field/pod-inventory" />
          <StatCard value={podKpis.expiring30} label="< 30 days" cardStyle={kpiCardStyle(podKpis.expiring30,'low')}      href="/field/pod-inventory" />
        </div>
      </SectionCard>
    </div>
  )
}

// ─── Driver Home ──────────────────────────────────────────────────────────────

function DriverHome({
  user,
  kpis,
  podKpis,
}: {
  user: UserInfo
  kpis: DriverKpis
  podKpis: PodExpiryKpis
}) {
  const router = useRouter()

  async function handleSignOut() {
    const supabase = createClient()
    await supabase.auth.signOut()
    router.push('/login')
  }

  return (
    <div className="px-4 py-4 pb-24">
      <h1 className="text-xl font-semibold">
        {getGreeting()}, {user.full_name ?? 'Driver'}
      </h1>
      <p className="mb-4 text-sm text-neutral-500">{formatToday()}</p>

      {/* ── Section 1: Today's Route ── */}
      <SectionCard title="Today's Route" linkTo="/field/trips">
        <div className="grid grid-cols-2 gap-3">
          <StatCard
            value={kpis.stopsToday}
            label="Stops today"
            cardStyle={kpiCardStyle(kpis.stopsToday > 0 ? 1 : 0, 'low')}
            href="/field/trips"
          />
          <StatCard
            value={kpis.pickupReady}
            label="Pickup ready"
            cardStyle={kpiCardStyle(kpis.pickupReady, 'medium')}
            href="/field/pickup"
          />
          <StatCard
            value={kpis.toDispatch}
            label="To dispatch"
            cardStyle={kpiCardStyle(kpis.toDispatch, 'medium')}
            href="/field/dispatching"
          />
          <StatCard
            value={kpis.openTasks}
            label="Open tasks"
            cardStyle={kpiCardStyle(kpis.openTasks, 'high')}
            href="/field/tasks"
          />
        </div>
        {kpis.openTasks > 0 && (
          <Link
            href="/field/tasks"
            className="mt-3 flex items-center justify-between rounded-xl bg-amber-50 px-4 py-3 text-sm font-medium text-amber-700 transition-colors hover:bg-amber-100"
          >
            <span>⚠ You have {kpis.openTasks} pending task{kpis.openTasks === 1 ? '' : 's'}</span>
            <span className="text-xs">View →</span>
          </Link>
        )}
      </SectionCard>

      {/* ── Section 2: Machine Stock Expiry ── */}
      <SectionCard title="Machine Stock Expiry" linkTo="/field/pod-inventory">
        <div className="grid grid-cols-2 gap-3">
          <StatCard value={podKpis.expired}    label="Expired"   cardStyle={kpiCardStyle(podKpis.expired,   'critical')} href="/field/pod-inventory" />
          <StatCard value={podKpis.expiring3}  label="< 3 days"  cardStyle={kpiCardStyle(podKpis.expiring3, 'high')}     href="/field/pod-inventory" />
          <StatCard value={podKpis.expiring7}  label="< 7 days"  cardStyle={kpiCardStyle(podKpis.expiring7, 'medium')}   href="/field/pod-inventory" />
          <StatCard value={podKpis.expiring30} label="< 30 days" cardStyle={kpiCardStyle(podKpis.expiring30,'low')}      href="/field/pod-inventory" />
        </div>
      </SectionCard>

      {/* ── Section 3: Profile ── */}
      <SectionCard title="Profile" linkTo="/field/profile">
        <div className="flex items-center justify-between rounded-xl bg-gray-50 px-4 py-3">
          <div>
            <p className="text-sm font-semibold text-gray-800">{user.full_name ?? 'Driver'}</p>
            <span className="mt-0.5 inline-block rounded bg-neutral-200 px-1.5 py-0.5 text-xs text-neutral-600 dark:bg-neutral-700 dark:text-neutral-300">
              Field Staff
            </span>
          </div>
          <button
            onClick={handleSignOut}
            className="rounded-lg bg-neutral-200 px-3 py-1.5 text-xs font-medium text-neutral-700 hover:bg-neutral-300 dark:bg-neutral-700 dark:text-neutral-200 dark:hover:bg-neutral-600"
          >
            Sign out
          </button>
        </div>
      </SectionCard>
    </div>
  )
}

// ─── Main Page ────────────────────────────────────────────────────────────────

export default function FieldPage() {
  const [user, setUser] = useState<UserInfo | null>(null)
  const [whKpis, setWhKpis] = useState<WarehouseKpis | null>(null)
  const [driverKpis, setDriverKpis] = useState<DriverKpis | null>(null)
  const [podKpis, setPodKpis] = useState<PodExpiryKpis | null>(null)

  const fetchData = useCallback(async () => {
    const supabase = createClient()
    const today = todayISO()

    // Get current user + role
    const { data: { user: authUser } } = await supabase.auth.getUser()
    if (!authUser) return

    const { data: profile } = await supabase
      .from('user_profiles')
      .select('full_name, role')
      .eq('id', authUser.id)
      .single()

    const role = (profile?.role ?? 'field_staff') as Role
    const fullName = profile?.full_name ?? null
    setUser({ full_name: fullName, role })

    if (role === 'warehouse') {
      const todayPlus3  = addDays(today, 3)
      const todayPlus7  = addDays(today, 7)
      const todayPlus30 = addDays(today, 30)

      const [
        { data: dispatchLines },
        { count: expiredCount },
        { count: expiring3Count },
        { count: expiring7Count },
        { count: expiring30Count },
        { data: openPOData },
        { count: activeInvCount },
        { count: expiryWeekCount },
        { count: receivedTodayCount },
        { data: lastControlRows },
      ] = await Promise.all([
        // Dispatch lines today — pick up packed/picked_up/dispatched counts
        supabase
          .from('refill_dispatching')
          .select('machine_id, packed, picked_up, dispatched')
          .eq('dispatch_date', today)
          .eq('include', true),
        // Expired warehouse inventory
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active')
          .lt('expiration_date', today),
        // Expiring within 3 days
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active')
          .gte('expiration_date', today)
          .lte('expiration_date', todayPlus3),
        // Expiring 3–7 days
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active')
          .gt('expiration_date', todayPlus3)
          .lte('expiration_date', todayPlus7),
        // Expiring 7–30 days
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active')
          .gt('expiration_date', todayPlus7)
          .lte('expiration_date', todayPlus30),
        // Open POs
        supabase
          .from('purchase_orders')
          .select('po_id')
          .is('received_date', null),
        // Active inventory item count
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active'),
        // Expiring ≤7 days (for internal use)
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active')
          .gte('expiration_date', today)
          .lte('expiration_date', todayPlus7),
        // Received today
        supabase
          .from('purchase_orders')
          .select('po_id', { count: 'exact', head: true })
          .eq('received_date', today),
        // Last inventory control
        supabase
          .from('inventory_control_log')
          .select('conducted_at')
          .order('conducted_at', { ascending: false })
          .limit(1),
      ])

      // Count distinct machines + line statuses
      const machineSet = new Set<string>()
      let packedCount = 0
      let pickedUpCount = 0
      let dispatchedCount = 0
      const totalCount = dispatchLines?.length ?? 0
      dispatchLines?.forEach((l) => {
        machineSet.add(l.machine_id)
        if (l.packed)      packedCount++
        if (l.picked_up)   pickedUpCount++
        if (l.dispatched)  dispatchedCount++
      })

      // Compute last control days
      let lastControlDays: number | null = null
      if (lastControlRows && lastControlRows.length > 0 && lastControlRows[0].conducted_at) {
        const controlDate = new Date(lastControlRows[0].conducted_at)
        const now = new Date()
        lastControlDays = Math.floor((now.getTime() - controlDate.getTime()) / 86400000)
      }

      setWhKpis({
        machinesToday:    machineSet.size,
        totalLines:       totalCount,
        packedLines:      packedCount,
        pickedUpLines:    pickedUpCount,
        dispatchedLines:  dispatchedCount,
        expired:          expiredCount ?? 0,
        expiring3:        expiring3Count ?? 0,
        expiring7:        expiring7Count ?? 0,
        expiring30:       expiring30Count ?? 0,
        openPOs:          new Set(openPOData?.map(r => r.po_id) ?? []).size,
        receivedToday:    receivedTodayCount ?? 0,
        activeItems:      activeInvCount ?? 0,
        expiringWeek:     expiryWeekCount ?? 0,
        lastControlDays,
      })

      // Pod inventory expiry KPIs
      const { data: podExpiryDataWh } = await supabase
        .from('pod_inventory')
        .select('expiration_date')
        .eq('status', 'Active')

      const podExpiredWh  = podExpiryDataWh?.filter(r => r.expiration_date && r.expiration_date < today).length ?? 0
      const podExp3Wh     = podExpiryDataWh?.filter(r => r.expiration_date && r.expiration_date >= today && r.expiration_date <= todayPlus3).length ?? 0
      const podExp7Wh     = podExpiryDataWh?.filter(r => r.expiration_date && r.expiration_date > todayPlus3 && r.expiration_date <= todayPlus7).length ?? 0
      const podExp30Wh    = podExpiryDataWh?.filter(r => r.expiration_date && r.expiration_date > todayPlus7 && r.expiration_date <= todayPlus30).length ?? 0
      setPodKpis({ expired: podExpiredWh, expiring3: podExp3Wh, expiring7: podExp7Wh, expiring30: podExp30Wh })

    } else {
      // Driver KPIs
      const [
        { data: dispatchLines },
        { data: openTasksData },
      ] = await Promise.all([
        supabase
          .from('refill_dispatching')
          .select('machine_id, packed, picked_up, dispatched')
          .eq('dispatch_date', today)
          .eq('include', true),
        supabase
          .from('driver_tasks')
          .select('task_id')
          .in('status', ['pending', 'acknowledged']),
      ])

      const machines = new Map<string, { packed: boolean[]; pickedUp: boolean[]; dispatched: boolean[] }>()
      dispatchLines?.forEach((l) => {
        const m = machines.get(l.machine_id) ?? { packed: [], pickedUp: [], dispatched: [] }
        m.packed.push(!!l.packed)
        m.pickedUp.push(!!l.picked_up)
        m.dispatched.push(!!l.dispatched)
        machines.set(l.machine_id, m)
      })

      let pickupReady = 0
      let toDispatch = 0
      machines.forEach((m) => {
        const allPacked     = m.packed.length > 0     && m.packed.every(Boolean)
        const allPickedUp   = m.pickedUp.length > 0   && m.pickedUp.every(Boolean)
        const allDispatched = m.dispatched.length > 0  && m.dispatched.every(Boolean)
        if (allPacked   && !allPickedUp)   pickupReady++
        if (allPickedUp && !allDispatched) toDispatch++
      })

      setDriverKpis({
        stopsToday: machines.size,
        pickupReady,
        toDispatch,
        openTasks: openTasksData?.length ?? 0,
      })

      // Pod inventory expiry KPIs
      const todayPlus3d  = addDays(today, 3)
      const todayPlus7d  = addDays(today, 7)
      const todayPlus30d = addDays(today, 30)

      const { data: podExpiryDataDr } = await supabase
        .from('pod_inventory')
        .select('expiration_date')
        .eq('status', 'Active')

      const podExpiredDr = podExpiryDataDr?.filter(r => r.expiration_date && r.expiration_date < today).length ?? 0
      const podExp3Dr    = podExpiryDataDr?.filter(r => r.expiration_date && r.expiration_date >= today && r.expiration_date <= todayPlus3d).length ?? 0
      const podExp7Dr    = podExpiryDataDr?.filter(r => r.expiration_date && r.expiration_date > todayPlus3d && r.expiration_date <= todayPlus7d).length ?? 0
      const podExp30Dr   = podExpiryDataDr?.filter(r => r.expiration_date && r.expiration_date > todayPlus7d && r.expiration_date <= todayPlus30d).length ?? 0
      setPodKpis({ expired: podExpiredDr, expiring3: podExp3Dr, expiring7: podExp7Dr, expiring30: podExp30Dr })
    }
  }, [])

  useEffect(() => {
    fetchData()
  }, [fetchData])

  useEffect(() => {
    function handleVisibility() {
      if (document.visibilityState === 'visible') fetchData()
    }
    document.addEventListener('visibilitychange', handleVisibility)
    window.addEventListener('focus', fetchData)
    return () => {
      document.removeEventListener('visibilitychange', handleVisibility)
      window.removeEventListener('focus', fetchData)
    }
  }, [fetchData])

  if (!user) return <Skeleton />

  if (user.role === 'warehouse') {
    if (!whKpis || !podKpis) return <Skeleton />
    return <WarehouseHome user={user} kpis={whKpis} podKpis={podKpis} />
  }

  if (!driverKpis || !podKpis) return <Skeleton />
  return <DriverHome user={user} kpis={driverKpis} podKpis={podKpis} />
}
