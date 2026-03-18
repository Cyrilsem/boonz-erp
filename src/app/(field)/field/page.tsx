'use client'

import { useEffect, useState, useCallback } from 'react'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'

type Role = 'warehouse' | 'field_staff'

interface UserInfo {
  full_name: string | null
  role: Role
}

interface WarehouseKpis {
  machinesToday: number
  packedLines: number
  totalLines: number
  expired: number
  expiring3: number
  expiring7: number
  expiring30: number
  openPOs: number
  activeItems: number
  expiringWeek: number
  pendingReceiving: number
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

function KpiCard({
  value,
  label,
  subLabel,
  colour,
  cardStyle,
  href,
}: {
  value: string | number
  label: string
  subLabel?: string
  colour?: 'blue' | 'green' | 'amber' | 'orange' | 'red' | 'grey'
  cardStyle?: KpiCardStyle
  href: string
}) {
  const colourMap = {
    blue:   'bg-blue-50 text-blue-700 dark:bg-blue-950 dark:text-blue-300',
    green:  'bg-green-50 text-green-700 dark:bg-green-950 dark:text-green-300',
    amber:  'bg-amber-50 text-amber-700 dark:bg-amber-950 dark:text-amber-300',
    orange: 'bg-orange-50 text-orange-700 dark:bg-orange-950 dark:text-orange-300',
    red:    'bg-red-50 text-red-700 dark:bg-red-950 dark:text-red-300',
    grey:   'bg-neutral-100 text-neutral-600 dark:bg-neutral-900 dark:text-neutral-400',
  }

  const containerClass = cardStyle
    ? `flex min-w-[130px] shrink-0 flex-col items-center rounded-xl border p-4 transition-opacity hover:opacity-80 ${cardStyle.bg} ${cardStyle.border} ${cardStyle.text}`
    : `flex min-w-[130px] shrink-0 flex-col items-center rounded-xl p-4 transition-opacity hover:opacity-80 ${colour ? colourMap[colour] : ''}`

  return (
    <Link href={href} className={containerClass}>
      <p className="text-2xl font-bold">{value}</p>
      <p className="mt-0.5 text-center text-xs font-medium">{label}</p>
      {subLabel && (
        <p className="mt-0.5 text-center text-[10px] opacity-70">{subLabel}</p>
      )}
    </Link>
  )
}

function CategoryCard({
  icon,
  title,
  sub,
  bgClass,
  sections,
  alert,
}: {
  icon: string
  title: string
  sub: string
  bgClass: string
  sections: { label: string; count: string; href: string }[]
  alert?: string
}) {
  return (
    <div className={`rounded-xl p-4 ${bgClass}`}>
      <div className="flex items-center gap-2 mb-1">
        <span className="text-xl">{icon}</span>
        <h2 className="text-base font-semibold">{title}</h2>
      </div>
      <p className="text-xs text-neutral-500 mb-3">{sub}</p>
      {alert && (
        <div className="mb-3 rounded-lg bg-red-100 px-3 py-2 text-xs font-medium text-red-700 dark:bg-red-900 dark:text-red-300">
          ⚠ {alert}
        </div>
      )}
      <div className="space-y-2">
        {sections.map((s) => (
          <Link
            key={s.href}
            href={s.href}
            className="flex items-center justify-between rounded-lg bg-white/60 px-3 py-2.5 text-sm transition-colors hover:bg-white/80 dark:bg-neutral-900/60 dark:hover:bg-neutral-900/80"
          >
            <span className="font-medium">{s.label}</span>
            <span className="text-xs text-neutral-500">{s.count} →</span>
          </Link>
        ))}
      </div>
    </div>
  )
}

function Skeleton() {
  return (
    <div className="px-4 py-4 pb-24 space-y-4 animate-pulse">
      <div className="h-7 w-48 rounded bg-neutral-200 dark:bg-neutral-800" />
      <div className="h-4 w-36 rounded bg-neutral-200 dark:bg-neutral-800" />
      <div className="flex gap-3 overflow-hidden">
        {[1, 2, 3, 4].map((i) => (
          <div key={i} className="h-20 w-32 shrink-0 rounded-xl bg-neutral-200 dark:bg-neutral-800" />
        ))}
      </div>
      {[1, 2, 3].map((i) => (
        <div key={i} className="h-36 rounded-xl bg-neutral-200 dark:bg-neutral-800" />
      ))}
    </div>
  )
}

// ─── Warehouse Home ───────────────────────────────────────────────

function WarehouseHome({ user, kpis, podKpis }: { user: UserInfo; kpis: WarehouseKpis; podKpis: PodExpiryKpis }) {
  const packPct = kpis.totalLines === 0
    ? 0
    : Math.round((kpis.packedLines / kpis.totalLines) * 100)

  const packColour = kpis.totalLines === 0
    ? 'grey' as const
    : packPct === 100
      ? 'green' as const
      : 'amber' as const

  const controlColour = kpis.lastControlDays === null
    ? 'red' as const
    : kpis.lastControlDays <= 7
      ? 'green' as const
      : kpis.lastControlDays <= 14
        ? 'amber' as const
        : 'red' as const

  const controlValue = kpis.lastControlDays === null
    ? 'Never'
    : kpis.lastControlDays === 0
      ? 'Today'
      : `${kpis.lastControlDays}d ago`

  return (
    <div className="px-4 py-4 pb-24">
      <h1 className="text-xl font-semibold">
        {getGreeting()}, {user.full_name ?? 'Warehouse'}
      </h1>
      <p className="text-sm text-neutral-500 mb-4">{formatToday()}</p>

      {/* KPI row 1 */}
      <div className="mb-3 flex gap-3 overflow-x-auto pb-1">
        <KpiCard
          value={kpis.machinesToday}
          label="To refill today"
          subLabel="machines scheduled"
          colour="blue"
          href="/field/packing"
        />
        <KpiCard
          value={`${packPct}%`}
          label="Packing complete"
          subLabel={`${kpis.packedLines}/${kpis.totalLines} lines`}
          colour={packColour}
          href="/field/packing"
        />
        <KpiCard
          value={kpis.openPOs}
          label="Open POs"
          colour={kpis.openPOs > 0 ? 'amber' : 'green'}
          href="/field/orders"
        />
        <KpiCard
          value={controlValue}
          label="Last control"
          colour={controlColour}
          href="/field/inventory"
        />
      </div>

      <p className="text-xs font-semibold text-neutral-500 uppercase tracking-wide mt-4 mb-2">Expiry Alerts</p>

      {/* KPI row 2 — expiry grid */}
      <div className="mb-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <KpiCard value={kpis.expired}   label="Expired"    cardStyle={kpiCardStyle(kpis.expired,   'critical')} href="/field/inventory" />
        <KpiCard value={kpis.expiring3} label="< 3 days"   cardStyle={kpiCardStyle(kpis.expiring3, 'high')}     href="/field/inventory" />
        <KpiCard value={kpis.expiring7} label="< 7 days"   cardStyle={kpiCardStyle(kpis.expiring7, 'medium')}   href="/field/inventory" />
        <KpiCard value={kpis.expiring30} label="< 30 days" cardStyle={kpiCardStyle(kpis.expiring30,'low')}      href="/field/inventory" />
      </div>

      <p className="text-xs font-semibold text-neutral-500 uppercase tracking-wide mt-4 mb-2">Machine Stock Expiry</p>

      {/* KPI row 3 — pod expiry grid */}
      <div className="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <KpiCard value={podKpis.expired}   label="Expired in machines" cardStyle={kpiCardStyle(podKpis.expired,   'critical')} href="/field/pod-inventory" />
        <KpiCard value={podKpis.expiring3} label="< 3 days"            cardStyle={kpiCardStyle(podKpis.expiring3, 'high')}     href="/field/pod-inventory" />
        <KpiCard value={podKpis.expiring7} label="< 7 days"            cardStyle={kpiCardStyle(podKpis.expiring7, 'medium')}   href="/field/pod-inventory" />
        <KpiCard value={podKpis.expiring30} label="< 30 days"          cardStyle={kpiCardStyle(podKpis.expiring30,'low')}      href="/field/pod-inventory" />
      </div>

      {/* Category cards */}
      <div className="space-y-3">
        <CategoryCard
          icon="📦"
          title="Daily Refills"
          sub="Pack and dispatch today's machines"
          bgClass="bg-blue-50/50 dark:bg-blue-950/30"
          sections={[
            { label: 'Packing', count: `${kpis.machinesToday} machines to pack`, href: '/field/packing' },
            { label: 'Receiving', count: `${kpis.pendingReceiving} deliveries pending`, href: '/field/receiving' },
          ]}
        />
        <CategoryCard
          icon="🗄️"
          title="Inventory Management"
          sub="Stock levels, locations, expiry tracking"
          bgClass="bg-teal-50/50 dark:bg-teal-950/30"
          sections={[
            { label: 'Warehouse Stock', count: `${kpis.activeItems} active items`, href: '/field/inventory' },
            { label: 'Expiry Sweep', count: `${kpis.expiringWeek} expiring this week`, href: '/field/inventory' },
          ]}
          alert={kpis.expired > 0 ? `${kpis.expired} items are expired` : kpis.expiring3 > 0 ? `${kpis.expiring3} items expire within 3 days` : undefined}
        />
        <CategoryCard
          icon="🛒"
          title="Procurement"
          sub="Purchase orders and supplier management"
          bgClass="bg-orange-50/50 dark:bg-orange-950/30"
          sections={[
            { label: 'Orders', count: `${kpis.openPOs} open POs`, href: '/field/orders' },
            { label: 'New Order', count: 'Create purchase order', href: '/field/orders/new' },
          ]}
        />
        <Link
          href="/field/profile"
          className="flex items-center gap-3 rounded-xl bg-neutral-100/50 p-4 transition-colors hover:bg-neutral-100 dark:bg-neutral-900/50 dark:hover:bg-neutral-900"
        >
          <span className="text-xl">👤</span>
          <div>
            <p className="text-base font-semibold">Profile</p>
            <p className="text-xs text-neutral-500">
              {user.full_name ?? 'User'} ·{' '}
              <span className="rounded bg-neutral-200 px-1.5 py-0.5 text-xs dark:bg-neutral-800">
                Warehouse
              </span>
            </p>
          </div>
        </Link>
      </div>
    </div>
  )
}

// ─── Driver Home ──────────────────────────────────────────────────

function DriverHome({ user, kpis, podKpis }: { user: UserInfo; kpis: DriverKpis; podKpis: PodExpiryKpis }) {
  return (
    <div className="px-4 py-4 pb-24">
      <h1 className="text-xl font-semibold">
        {getGreeting()}, {user.full_name ?? 'Driver'}
      </h1>
      <p className="text-sm text-neutral-500 mb-4">{formatToday()}</p>

      {/* KPI row */}
      <div className="mb-5 flex gap-3 overflow-x-auto pb-1">
        <KpiCard value={kpis.stopsToday} label="Stops today" colour="blue" href="/field/trips" />
        <KpiCard
          value={kpis.pickupReady}
          label="Ready to collect"
          colour={kpis.pickupReady > 0 ? 'amber' : 'green'}
          href="/field/pickup"
        />
        <KpiCard
          value={kpis.toDispatch}
          label="To dispatch"
          colour={kpis.toDispatch > 0 ? 'orange' : 'green'}
          href="/field/dispatching"
        />
        <KpiCard
          value={kpis.openTasks}
          label="Open tasks"
          colour={kpis.openTasks > 0 ? 'red' : 'green'}
          href="/field/tasks"
        />
      </div>

      <p className="text-xs font-semibold text-neutral-500 uppercase tracking-wide mt-4 mb-2">Machine Stock Expiry</p>

      {/* Pod expiry grid */}
      <div className="mb-5 grid grid-cols-2 gap-3 sm:grid-cols-4">
        <KpiCard value={podKpis.expired}    label="Expired in machines" cardStyle={kpiCardStyle(podKpis.expired,   'critical')} href="/field/pod-inventory" />
        <KpiCard value={podKpis.expiring3}  label="< 3 days"            cardStyle={kpiCardStyle(podKpis.expiring3, 'high')}     href="/field/pod-inventory" />
        <KpiCard value={podKpis.expiring7}  label="< 7 days"            cardStyle={kpiCardStyle(podKpis.expiring7, 'medium')}   href="/field/pod-inventory" />
        <KpiCard value={podKpis.expiring30} label="< 30 days"           cardStyle={kpiCardStyle(podKpis.expiring30,'low')}      href="/field/pod-inventory" />
      </div>

      {/* Activity cards */}
      <div className="space-y-3">
        <CategoryCard
          icon="🗺️"
          title="Today's Route"
          sub="Your machine stops for today"
          bgClass="bg-blue-50/50 dark:bg-blue-950/30"
          sections={[
            { label: 'All stops', count: `${kpis.stopsToday} machines`, href: '/field/trips' },
            { label: 'Pickup', count: `${kpis.pickupReady} ready to collect`, href: '/field/pickup' },
            { label: 'Dispatch', count: `${kpis.toDispatch} to dispatch`, href: '/field/dispatching' },
          ]}
        />
        <CategoryCard
          icon="🛒"
          title="Tasks"
          sub="Supplier collections and ad-hoc tasks"
          bgClass="bg-amber-50/50 dark:bg-amber-950/30"
          sections={[
            { label: 'Open tasks', count: `${kpis.openTasks} pending`, href: '/field/tasks' },
          ]}
          alert={kpis.openTasks > 0 ? `You have ${kpis.openTasks} pending task(s)` : undefined}
        />
        <Link
          href="/field/profile"
          className="flex items-center gap-3 rounded-xl bg-neutral-100/50 p-4 transition-colors hover:bg-neutral-100 dark:bg-neutral-900/50 dark:hover:bg-neutral-900"
        >
          <span className="text-xl">👤</span>
          <div>
            <p className="text-base font-semibold">Profile</p>
            <p className="text-xs text-neutral-500">
              {user.full_name ?? 'User'} · Driver
            </p>
          </div>
        </Link>
      </div>
    </div>
  )
}

// ─── Main Page ────────────────────────────────────────────────────

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
      // Precompute date boundaries
      const todayPlus3 = addDays(today, 3)
      const todayPlus7 = addDays(today, 7)
      const todayPlus30 = addDays(today, 30)

      // Warehouse KPIs
      const [
        { data: dispatchLines },
        { count: expiredCount },
        { count: expiring3Count },
        { count: expiring7Count },
        { count: expiring30Count },
        { data: openPOData },
        { count: activeInvCount },
        { count: expiryWeekCount },
        { data: pendingPOLines },
        { data: lastControlRows },
      ] = await Promise.all([
        // Dispatch lines today
        supabase
          .from('refill_dispatching')
          .select('machine_id, packed')
          .eq('dispatch_date', today)
          .eq('include', true),
        // Expired: expiration_date < today
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active')
          .lt('expiration_date', today),
        // Expiring within 3 days: >= today AND <= today+3
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active')
          .gte('expiration_date', today)
          .lte('expiration_date', todayPlus3),
        // Expiring 3-7 days: > today+3 AND <= today+7
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active')
          .gt('expiration_date', todayPlus3)
          .lte('expiration_date', todayPlus7),
        // Expiring 7-30 days: > today+7 AND <= today+30
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active')
          .gt('expiration_date', todayPlus7)
          .lte('expiration_date', todayPlus30),
        // Open POs (distinct)
        supabase
          .from('purchase_orders')
          .select('po_id')
          .is('received_date', null),
        // Active inventory items
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active'),
        // Expiring <=7 days (for category card)
        supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id', { count: 'exact', head: true })
          .eq('status', 'Active')
          .gte('expiration_date', today)
          .lte('expiration_date', todayPlus7),
        // Pending receiving
        supabase
          .from('purchase_orders')
          .select('po_id')
          .is('received_date', null),
        // Last inventory control
        supabase
          .from('inventory_control_log')
          .select('conducted_at')
          .order('conducted_at', { ascending: false })
          .limit(1),
      ])

      // Count distinct machines
      const machineSet = new Set<string>()
      let packedCount = 0
      const totalCount = dispatchLines?.length ?? 0
      dispatchLines?.forEach((l) => {
        machineSet.add(l.machine_id)
        if (l.packed) packedCount++
      })

      // Count distinct POs for receiving
      const pendingPOSet = new Set<string>()
      pendingPOLines?.forEach((l) => pendingPOSet.add(l.po_id))

      // Compute last control days
      let lastControlDays: number | null = null
      if (lastControlRows && lastControlRows.length > 0 && lastControlRows[0].conducted_at) {
        const controlDate = new Date(lastControlRows[0].conducted_at)
        const now = new Date()
        lastControlDays = Math.floor((now.getTime() - controlDate.getTime()) / 86400000)
      }

      setWhKpis({
        machinesToday: machineSet.size,
        packedLines: packedCount,
        totalLines: totalCount,
        expired: expiredCount ?? 0,
        expiring3: expiring3Count ?? 0,
        expiring7: expiring7Count ?? 0,
        expiring30: expiring30Count ?? 0,
        openPOs: new Set(openPOData?.map(r => r.po_id) ?? []).size,
        activeItems: activeInvCount ?? 0,
        expiringWeek: expiryWeekCount ?? 0,
        pendingReceiving: pendingPOSet.size,
        lastControlDays,
      })

      // Pod inventory expiry KPIs
      const { data: podExpiryDataWh } = await supabase
        .from('pod_inventory')
        .select('expiration_date')
        .eq('status', 'Active')

      const podExpiredWh = podExpiryDataWh?.filter(r => r.expiration_date && r.expiration_date < today).length ?? 0
      const podExp3Wh = podExpiryDataWh?.filter(r => r.expiration_date && r.expiration_date >= today && r.expiration_date <= todayPlus3).length ?? 0
      const podExp7Wh = podExpiryDataWh?.filter(r => r.expiration_date && r.expiration_date > todayPlus3 && r.expiration_date <= todayPlus7).length ?? 0
      const podExp30Wh = podExpiryDataWh?.filter(r => r.expiration_date && r.expiration_date > todayPlus7 && r.expiration_date <= todayPlus30).length ?? 0
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

      // Group by machine
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
        const allPacked = m.packed.length > 0 && m.packed.every(Boolean)
        const allPickedUp = m.pickedUp.length > 0 && m.pickedUp.every(Boolean)
        const allDispatched = m.dispatched.length > 0 && m.dispatched.every(Boolean)

        if (allPacked && !allPickedUp) pickupReady++
        if (allPickedUp && !allDispatched) toDispatch++
      })

      setDriverKpis({
        stopsToday: machines.size,
        pickupReady,
        toDispatch,
        openTasks: openTasksData?.length ?? 0,
      })

      // Pod inventory expiry KPIs
      const todayPlus3d = addDays(today, 3)
      const todayPlus7d = addDays(today, 7)
      const todayPlus30d = addDays(today, 30)

      const { data: podExpiryDataDr } = await supabase
        .from('pod_inventory')
        .select('expiration_date')
        .eq('status', 'Active')

      const podExpiredDr = podExpiryDataDr?.filter(r => r.expiration_date && r.expiration_date < today).length ?? 0
      const podExp3Dr = podExpiryDataDr?.filter(r => r.expiration_date && r.expiration_date >= today && r.expiration_date <= todayPlus3d).length ?? 0
      const podExp7Dr = podExpiryDataDr?.filter(r => r.expiration_date && r.expiration_date > todayPlus3d && r.expiration_date <= todayPlus7d).length ?? 0
      const podExp30Dr = podExpiryDataDr?.filter(r => r.expiration_date && r.expiration_date > todayPlus7d && r.expiration_date <= todayPlus30d).length ?? 0
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
