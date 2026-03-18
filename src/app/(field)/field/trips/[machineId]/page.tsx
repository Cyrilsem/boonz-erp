'use client'

import { useEffect, useState, useCallback } from 'react'
import { useParams, useRouter } from 'next/navigation'
import Link from 'next/link'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'

interface MachineInfo {
  official_name: string
  pod_location: string | null
  pod_address: string | null
  latitude: number | null
  longitude: number | null
}

interface RefillLine {
  dispatch_id: string
  shelf_code: string
  pod_product_name: string
  quantity: number
  filled_quantity: number
  dispatched: boolean
  confirmed: boolean
  comment: string
}

export default function MachineRefillPage() {
  const params = useParams<{ machineId: string }>()
  const router = useRouter()
  const machineId = params.machineId

  const [machine, setMachine] = useState<MachineInfo | null>(null)
  const [lines, setLines] = useState<RefillLine[]>([])
  const [loading, setLoading] = useState(true)
  const [checkedIn, setCheckedIn] = useState(false)
  const [checkingIn, setCheckingIn] = useState(false)
  const [gpsWarning, setGpsWarning] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)

  const fetchData = useCallback(async () => {
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    const { data: machineData } = await supabase
      .from('machines')
      .select('official_name, pod_location, pod_address, latitude, longitude')
      .eq('machine_id', machineId)
      .single()

    if (machineData) {
      setMachine(machineData)
    }

    // Check if already checked in today
    const { data: { user } } = await supabase.auth.getUser()
    if (user) {
      const { data: existingCheckIn } = await supabase
        .from('trip_events')
        .select('id')
        .eq('machine_id', machineId)
        .eq('driver_user_id', user.id)
        .eq('event_type', 'check_in')
        .eq('dispatch_date', today)
        .limit(1)

      if (existingCheckIn && existingCheckIn.length > 0) {
        setCheckedIn(true)
      }
    }

    const { data: dispatchLines } = await supabase
      .from('refill_dispatching')
      .select(`
        dispatch_id,
        quantity,
        filled_quantity,
        dispatched,
        comment,
        shelf_id,
        shelf_configurations!inner(shelf_code),
        pod_products!inner(pod_product_name)
      `)
      .eq('dispatch_date', today)
      .eq('include', true)
      .eq('machine_id', machineId)
      .eq('picked_up', true)

    if (dispatchLines) {
      const mapped: RefillLine[] = dispatchLines.map((line) => {
        const shelf = line.shelf_configurations as unknown as { shelf_code: string }
        const product = line.pod_products as unknown as { pod_product_name: string }
        return {
          dispatch_id: line.dispatch_id,
          shelf_code: shelf.shelf_code,
          pod_product_name: product.pod_product_name,
          quantity: line.quantity ?? 0,
          filled_quantity: line.filled_quantity ?? line.quantity ?? 0,
          dispatched: !!line.dispatched,
          confirmed: !!line.dispatched,
          comment: (line.comment as string) ?? '',
        }
      })
      mapped.sort((a, b) => a.shelf_code.localeCompare(b.shelf_code))
      setLines(mapped)
    }

    setLoading(false)
  }, [machineId])

  useEffect(() => {
    fetchData()
  }, [fetchData])

  async function handleCheckIn() {
    setCheckingIn(true)
    setGpsWarning(null)

    try {
      const position = await new Promise<GeolocationPosition>((resolve, reject) => {
        navigator.geolocation.getCurrentPosition(resolve, reject, {
          enableHighAccuracy: true,
          timeout: 10000,
        })
      })

      const lat = position.coords.latitude
      const lng = position.coords.longitude

      let varianceM: number | null = null
      if (machine?.latitude && machine?.longitude) {
        varianceM = haversineDistance(
          lat, lng,
          machine.latitude, machine.longitude
        )
        if (varianceM > 200) {
          setGpsWarning('You appear to be at a different location')
        }
      }

      const supabase = createClient()
      const { data: { user } } = await supabase.auth.getUser()
      const today = new Date().toISOString().split('T')[0]

      if (user) {
        await supabase
          .from('trip_events')
          .upsert(
            {
              machine_id: machineId,
              driver_user_id: user.id,
              event_type: 'check_in',
              dispatch_date: today,
              latitude: lat,
              longitude: lng,
              gps_variance_m: varianceM,
            },
            { onConflict: 'machine_id,driver_user_id,event_type,dispatch_date' }
          )
      }

      setCheckedIn(true)
    } catch {
      // Geolocation failed — still allow check-in without GPS
      const supabase = createClient()
      const { data: { user } } = await supabase.auth.getUser()
      const today = new Date().toISOString().split('T')[0]

      if (user) {
        await supabase
          .from('trip_events')
          .upsert(
            {
              machine_id: machineId,
              driver_user_id: user.id,
              event_type: 'check_in',
              dispatch_date: today,
            },
            { onConflict: 'machine_id,driver_user_id,event_type,dispatch_date' }
          )
      }

      setCheckedIn(true)
      setGpsWarning('Could not get GPS location')
    }

    setCheckingIn(false)
  }

  function updateLineComment(dispatchId: string, value: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, comment: value } : l
      )
    )
  }

  async function saveLineComment(dispatchId: string, value: string) {
    const supabase = createClient()
    await supabase
      .from('refill_dispatching')
      .update({ comment: value.trim() || null })
      .eq('dispatch_id', dispatchId)
  }

  function updateLineQuantity(dispatchId: string, value: number) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, filled_quantity: value } : l
      )
    )
  }

  function toggleLineConfirmed(dispatchId: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, confirmed: !l.confirmed } : l
      )
    )
  }

  async function handleSubmit() {
    setSubmitting(true)
    const supabase = createClient()

    const updates = lines
      .filter((l) => l.confirmed)
      .map((l) =>
        supabase
          .from('refill_dispatching')
          .update({
            filled_quantity: l.filled_quantity,
            dispatched: true,
            comment: l.comment.trim() || null,
          })
          .eq('dispatch_id', l.dispatch_id)
      )

    await Promise.all(updates)
    router.push('/field/trips')
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Machine Refill" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading machine details…</p>
        </div>
      </>
    )
  }

  // Group lines by shelf
  const grouped = new Map<string, RefillLine[]>()
  for (const line of lines) {
    const existing = grouped.get(line.shelf_code) ?? []
    existing.push(line)
    grouped.set(line.shelf_code, existing)
  }
  const shelves = Array.from(grouped.entries()).sort((a, b) =>
    a[0].localeCompare(b[0])
  )

  const allConfirmed = lines.length > 0 && lines.every((l) => l.confirmed)

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Machine Refill" />

      {machine && (
        <div className="mb-4">
          <h1 className="text-xl font-semibold">{machine.official_name}</h1>
          {machine.pod_location && (
            <p className="text-sm text-neutral-500">{machine.pod_location}</p>
          )}
          {machine.pod_address && (
            <p className="text-sm text-neutral-400">{machine.pod_address}</p>
          )}
        </div>
      )}

      {/* Check-in button */}
      {!checkedIn ? (
        <button
          onClick={handleCheckIn}
          disabled={checkingIn}
          className="mb-4 w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          {checkingIn ? 'Checking in…' : 'CHECK IN'}
        </button>
      ) : (
        <div className="mb-4 rounded-lg bg-green-50 p-3 text-center text-sm font-medium text-green-700 dark:bg-green-950 dark:text-green-300">
          Checked in ✓
        </div>
      )}

      {gpsWarning && (
        <div className="mb-4 rounded-lg bg-amber-50 p-3 text-center text-sm text-amber-700 dark:bg-amber-950 dark:text-amber-300">
          {gpsWarning}
        </div>
      )}

      {/* Action buttons */}
      <div className="mb-4 flex gap-2">
        <Link
          href={`/field/trips/${machineId}/removals`}
          className="flex-1 rounded-lg border border-neutral-200 py-2.5 text-center text-sm font-medium transition-colors hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-900"
        >
          Log removals
        </Link>
        <Link
          href={`/field/trips/${machineId}/issue`}
          className="flex-1 rounded-lg border border-neutral-200 py-2.5 text-center text-sm font-medium transition-colors hover:bg-neutral-50 dark:border-neutral-700 dark:hover:bg-neutral-900"
        >
          Report issue
        </Link>
      </div>

      {/* Refill lines */}
      {shelves.map(([shelfCode, shelfLines]) => (
        <div key={shelfCode} className="mb-4">
          <h2 className="mb-2 text-sm font-semibold text-neutral-500 uppercase tracking-wide">
            Shelf {shelfCode}
          </h2>
          <ul className="space-y-1">
            {shelfLines.map((line) => (
              <li
                key={line.dispatch_id}
                className="flex items-center gap-3 rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
              >
                <button
                  onClick={() => toggleLineConfirmed(line.dispatch_id)}
                  className={`flex h-6 w-6 shrink-0 items-center justify-center rounded border text-sm ${
                    line.confirmed
                      ? 'border-green-500 bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                      : 'border-neutral-300 bg-white hover:bg-neutral-50 dark:border-neutral-600 dark:bg-neutral-900'
                  }`}
                >
                  {line.confirmed ? '✓' : ''}
                </button>
                <div className="flex-1 min-w-0">
                  <p className="text-sm font-medium truncate">
                    {line.pod_product_name}
                  </p>
                  <p className="text-xs text-neutral-500">
                    Planned: {line.quantity}
                  </p>
                  <input
                    type="text"
                    value={line.comment}
                    onChange={(e) => updateLineComment(line.dispatch_id, e.target.value)}
                    onBlur={(e) => saveLineComment(line.dispatch_id, e.target.value)}
                    placeholder="Add note…"
                    className="mt-1 w-full rounded border border-neutral-200 px-2 py-1 text-xs text-neutral-600 placeholder:text-neutral-400 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-400"
                  />
                </div>
                <input
                  type="number"
                  min={0}
                  value={line.filled_quantity}
                  onChange={(e) =>
                    updateLineQuantity(
                      line.dispatch_id,
                      parseFloat(e.target.value) || 0
                    )
                  }
                  className="w-16 rounded border border-neutral-300 px-2 py-1 text-center text-sm dark:border-neutral-600 dark:bg-neutral-900"
                />
              </li>
            ))}
          </ul>
        </div>
      ))}

      {/* Submit button */}
      <button
        onClick={handleSubmit}
        disabled={submitting || !allConfirmed}
        className="mt-4 w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-40 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
      >
        {submitting ? 'Submitting…' : 'Submit refill'}
      </button>
    </div>
  )
}

/** Haversine distance in metres between two lat/lng points */
function haversineDistance(
  lat1: number, lon1: number,
  lat2: number, lon2: number
): number {
  const R = 6371000
  const toRad = (d: number) => (d * Math.PI) / 180
  const dLat = toRad(lat2 - lat1)
  const dLon = toRad(lon2 - lon1)
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}
