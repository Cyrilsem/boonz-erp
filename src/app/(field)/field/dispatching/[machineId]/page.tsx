'use client'

import { useEffect, useState, useCallback, useMemo } from 'react'
import { useParams } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'
import { usePageTour } from '../../../components/onboarding/use-page-tour'
import Tour from '../../../components/onboarding/tour'
import { getExpiryStyle } from '@/app/(field)/utils/expiry'

// ─── Types ────────────────────────────────────────────────────────────────────

interface MachineInfo {
  official_name: string
  pod_location: string | null
}

interface DispatchPhoto {
  path: string
  url: string
}

interface DispatchLine {
  dispatch_id: string
  boonz_product_id: string | null
  shelf_id: string | null
  shelf_code: string
  pod_product_name: string
  quantity: number
  filled_quantity: number
  dispatched: boolean
  expiry_date: string | null
  comment: string
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

function formatDMY(date: string | null): string {
  if (!date) return '—'
  return new Date(date + 'T00:00:00').toLocaleDateString('en-GB', {
    day: '2-digit', month: 'short', year: '2-digit',
  })
}

// ─── Page ─────────────────────────────────────────────────────────────────────

export default function DispatchingDetailPage() {
  const params = useParams<{ machineId: string }>()
  const machineId = params.machineId
  const { showTour, tourSteps, completeTour } = usePageTour('dispatching')

  const [machine, setMachine] = useState<MachineInfo | null>(null)
  const [lines, setLines] = useState<DispatchLine[]>([])
  const [invWarnings, setInvWarnings] = useState<Record<string, string>>({})
  const [loading, setLoading] = useState(true)
  const [markingAll, setMarkingAll] = useState(false)

  // Photos
  const [beforePhoto, setBeforePhoto] = useState<DispatchPhoto | null>(null)
  const [afterPhoto, setAfterPhoto] = useState<DispatchPhoto | null>(null)
  const [photoUploading, setPhotoUploading] = useState<'before' | 'after' | null>(null)

  const fetchData = useCallback(async () => {
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    const { data: machineData } = await supabase
      .from('machines')
      .select('official_name, pod_location')
      .eq('machine_id', machineId)
      .single()

    if (machineData) setMachine(machineData)

    const { data: dispatchLines } = await supabase
      .from('refill_dispatching')
      .select(`
        dispatch_id,
        boonz_product_id,
        shelf_id,
        quantity,
        filled_quantity,
        dispatched,
        expiry_date,
        comment,
        shelf_configurations!inner(shelf_code),
        pod_products!inner(pod_product_name)
      `)
      .eq('dispatch_date', today)
      .eq('include', true)
      .eq('machine_id', machineId)
      .eq('picked_up', true)

    if (dispatchLines) {
      const mapped: DispatchLine[] = dispatchLines.map((line) => {
        const shelf = line.shelf_configurations as unknown as { shelf_code: string }
        const product = line.pod_products as unknown as { pod_product_name: string }
        return {
          dispatch_id: line.dispatch_id,
          boonz_product_id: (line.boonz_product_id as string | null) ?? null,
          shelf_id: (line.shelf_id as string | null) ?? null,
          shelf_code: shelf.shelf_code,
          pod_product_name: product.pod_product_name,
          quantity: line.quantity ?? 0,
          filled_quantity: line.filled_quantity ?? line.quantity ?? 0,
          dispatched: !!line.dispatched,
          expiry_date: (line.expiry_date as string | null) ?? null,
          comment: (line.comment as string) ?? '',
        }
      })
      mapped.sort((a, b) => a.shelf_code.localeCompare(b.shelf_code))
      setLines(mapped)
    }

    // Photos for today
    const { data: photoData } = await supabase
      .from('dispatch_photos')
      .select('photo_type, storage_path')
      .eq('machine_id', machineId)
      .eq('dispatch_date', today)

    for (const p of photoData ?? []) {
      const { data: { publicUrl } } = supabase.storage
        .from('dispatch-photos')
        .getPublicUrl(p.storage_path)
      if (p.photo_type === 'before') setBeforePhoto({ path: p.storage_path, url: publicUrl })
      if (p.photo_type === 'after')  setAfterPhoto({ path: p.storage_path, url: publicUrl })
    }

    setLoading(false)
  }, [machineId])

  useEffect(() => { fetchData() }, [fetchData])

  // Products with mixed expiry dates across their dispatch lines
  const mixedDateProducts = useMemo(() => {
    const byProduct = new Map<string, Set<string>>()
    for (const l of lines) {
      if (!l.expiry_date || !l.boonz_product_id) continue
      if (!byProduct.has(l.boonz_product_id)) byProduct.set(l.boonz_product_id, new Set())
      byProduct.get(l.boonz_product_id)!.add(l.expiry_date)
    }
    const mixed = new Set<string>()
    for (const [pid, dates] of byProduct) {
      if (dates.size > 1) mixed.add(pid)
    }
    return mixed
  }, [lines])

  // ── Photo capture ──────────────────────────────────────────────────────────

  async function compressImage(file: File): Promise<Blob> {
    return new Promise((resolve) => {
      const img = new Image()
      const blobUrl = URL.createObjectURL(file)
      img.onload = () => {
        URL.revokeObjectURL(blobUrl)
        const maxW = 1200
        let { width, height } = img
        if (width > maxW) {
          height = Math.round((height * maxW) / width)
          width = maxW
        }
        const canvas = document.createElement('canvas')
        canvas.width = width
        canvas.height = height
        const ctx = canvas.getContext('2d')!
        ctx.drawImage(img, 0, 0, width, height)
        canvas.toBlob((blob) => resolve(blob!), 'image/jpeg', 0.7)
      }
      img.src = blobUrl
    })
  }

  async function handlePhotoCapture(type: 'before' | 'after', file: File) {
    setPhotoUploading(type)
    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()

    try {
      const compressed = await compressImage(file)
      const today = new Date().toISOString().split('T')[0]
      const timestamp = Date.now()
      const path = `${machineId}/${today}/${type}-${timestamp}.jpg`

      const { error: uploadError } = await supabase.storage
        .from('dispatch-photos')
        .upload(path, compressed, { contentType: 'image/jpeg' })
      if (uploadError) throw uploadError

      const { data: { publicUrl } } = supabase.storage
        .from('dispatch-photos')
        .getPublicUrl(path)

      await supabase.from('dispatch_photos').insert({
        machine_id: machineId,
        dispatch_date: today,
        photo_type: type,
        storage_path: path,
        taken_by: user?.id ?? null,
      })

      if (type === 'before') setBeforePhoto({ path, url: publicUrl })
      else setAfterPhoto({ path, url: publicUrl })
    } catch {
      // Silent fail — photos are optional
    }

    setPhotoUploading(null)
  }

  // ── Inventory update logic (non-blocking) ──────────────────────────────────

  async function runInventoryUpdates(line: DispatchLine): Promise<string | null> {
    const productId = line.boonz_product_id
    if (!productId) return null

    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    // A — Deduct from warehouse_inventory
    try {
      interface WhRow { wh_inventory_id: string; warehouse_stock: number }
      let whRow: WhRow | null = null

      if (line.expiry_date) {
        const { data } = await supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id, warehouse_stock')
          .eq('boonz_product_id', productId)
          .eq('expiration_date', line.expiry_date)
          .eq('status', 'Active')
          .limit(1)
        whRow = ((data ?? []) as WhRow[])[0] ?? null
      }

      if (!whRow) {
        // FIFO fallback — earliest non-null expiry
        const { data } = await supabase
          .from('warehouse_inventory')
          .select('wh_inventory_id, warehouse_stock')
          .eq('boonz_product_id', productId)
          .eq('status', 'Active')
          .order('expiration_date', { ascending: true, nullsFirst: false })
          .limit(1)
        whRow = ((data ?? []) as WhRow[])[0] ?? null
      }

      if (whRow) {
        const newStock = Math.max(0, (whRow.warehouse_stock ?? 0) - line.filled_quantity)
        const { error } = await supabase
          .from('warehouse_inventory')
          .update({ warehouse_stock: newStock })
          .eq('wh_inventory_id', whRow.wh_inventory_id)
        if (error) throw error
      } else {
        console.warn('[Dispatch] No warehouse batch found for product', productId)
      }
    } catch (err) {
      console.error('[Dispatch] Warehouse deduction failed:', err)
      return '⚠ Inventory update failed'
    }

    // B — Update pod_inventory
    if (line.shelf_id) {
      try {
        interface PodRow { pod_inventory_id: string; current_stock: number }
        const { data: existingRows } = await supabase
          .from('pod_inventory')
          .select('pod_inventory_id, current_stock')
          .eq('machine_id', machineId)
          .eq('shelf_id', line.shelf_id)
          .eq('boonz_product_id', productId)
          .eq('status', 'Active')
          .order('snapshot_date', { ascending: false })
          .limit(1)

        const existingPod = ((existingRows ?? []) as PodRow[])[0] ?? null

        if (existingPod) {
          const { error } = await supabase
            .from('pod_inventory')
            .update({
              current_stock: (existingPod.current_stock ?? 0) + line.filled_quantity,
              expiration_date: line.expiry_date,
              snapshot_date: today,
            })
            .eq('pod_inventory_id', existingPod.pod_inventory_id)
          if (error) throw error
        } else {
          const { error } = await supabase
            .from('pod_inventory')
            .insert({
              machine_id: machineId,
              shelf_id: line.shelf_id,
              boonz_product_id: productId,
              current_stock: line.filled_quantity,
              expiration_date: line.expiry_date,
              batch_id: `DISPATCH-${today}`,
              status: 'Active',
              snapshot_date: today,
            })
          if (error) throw error
        }
      } catch (err) {
        console.error('[Dispatch] Pod inventory update failed:', err)
        return '⚠ Inventory update failed'
      }
    }

    return null
  }

  // ── Line actions ───────────────────────────────────────────────────────────

  function updateQuantity(dispatchId: string, value: number) {
    setLines((prev) =>
      prev.map((l) => l.dispatch_id === dispatchId ? { ...l, filled_quantity: value } : l)
    )
  }

  function updateComment(dispatchId: string, value: string) {
    setLines((prev) =>
      prev.map((l) => l.dispatch_id === dispatchId ? { ...l, comment: value } : l)
    )
  }

  async function saveComment(dispatchId: string, value: string) {
    const supabase = createClient()
    await supabase
      .from('refill_dispatching')
      .update({ comment: value.trim() || null })
      .eq('dispatch_id', dispatchId)
  }

  async function handleDispatchLine(dispatchId: string) {
    const line = lines.find((l) => l.dispatch_id === dispatchId)
    if (!line || line.dispatched) return

    const supabase = createClient()
    await supabase
      .from('refill_dispatching')
      .update({
        dispatched: true,
        filled_quantity: line.filled_quantity,
        item_added: true,
        comment: line.comment.trim() || null,
      })
      .eq('dispatch_id', dispatchId)

    setLines((prev) =>
      prev.map((l) => l.dispatch_id === dispatchId ? { ...l, dispatched: true } : l)
    )

    // Inventory updates — non-blocking, dispatch confirmed regardless
    const warning = await runInventoryUpdates(line)
    if (warning) {
      setInvWarnings((prev) => ({ ...prev, [dispatchId]: warning }))
    }
  }

  async function handleMarkAllDispatched() {
    setMarkingAll(true)
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]
    const undispatched = lines.filter((l) => !l.dispatched)

    // Sequential — avoid inventory conflicts; dispatch confirmed per line
    for (const l of undispatched) {
      await supabase
        .from('refill_dispatching')
        .update({
          dispatched: true,
          filled_quantity: l.filled_quantity,
          item_added: true,
          comment: l.comment.trim() || null,
        })
        .eq('dispatch_id', l.dispatch_id)
        .eq('dispatch_date', today)

      const warning = await runInventoryUpdates(l)
      if (warning) {
        setInvWarnings((prev) => ({ ...prev, [l.dispatch_id]: warning }))
      }
    }

    setLines((prev) => prev.map((l) => ({ ...l, dispatched: true })))
    setMarkingAll(false)
  }

  if (loading) {
    return (
      <>
        <FieldHeader title="Dispatch Detail" />
        <div className="flex items-center justify-center p-8">
          <p className="text-neutral-500">Loading dispatch details…</p>
        </div>
      </>
    )
  }

  const doneCount = lines.filter((l) => l.dispatched).length
  const allDone = lines.length > 0 && doneCount === lines.length

  const grouped = new Map<string, DispatchLine[]>()
  for (const line of lines) {
    const existing = grouped.get(line.shelf_code) ?? []
    existing.push(line)
    grouped.set(line.shelf_code, existing)
  }
  const shelves = Array.from(grouped.entries()).sort((a, b) => a[0].localeCompare(b[0]))

  return (
    <div className="px-4 py-4 pb-24">
      <FieldHeader title="Dispatch Detail" />
      {showTour && tourSteps.length > 0 && (
        <Tour steps={tourSteps} onComplete={completeTour} onSkip={completeTour} />
      )}

      {/* ── Machine photos ── */}
      <div data-tour="dispatch-photos" className="mb-5">
        <p className="text-sm font-bold uppercase tracking-wide text-neutral-500">Machine photos</p>
        <p className="mb-3 text-xs text-neutral-400">Take a photo before and after refilling</p>
        <div className="grid grid-cols-2 gap-3">
          {(['before', 'after'] as const).map((type) => {
            const photo = type === 'before' ? beforePhoto : afterPhoto
            const uploading = photoUploading === type
            return (
              <div key={type} className="relative">
                {photo ? (
                  <div className="relative overflow-hidden rounded-xl">
                    {/* eslint-disable-next-line @next/next/no-img-element */}
                    <img
                      src={photo.url}
                      alt={`${type} photo`}
                      className="h-32 w-full object-cover"
                    />
                    <label className="absolute bottom-1 right-1 cursor-pointer rounded-lg bg-black/60 px-2 py-0.5 text-xs text-white">
                      Retake
                      <input
                        type="file"
                        accept="image/*"
                        capture="environment"
                        className="sr-only"
                        onChange={(e) => {
                          const file = e.target.files?.[0]
                          if (file) handlePhotoCapture(type, file)
                        }}
                      />
                    </label>
                  </div>
                ) : (
                  <label className="flex h-32 cursor-pointer flex-col items-center justify-center gap-1 rounded-xl border-2 border-dashed border-neutral-300 bg-neutral-50 text-neutral-400 transition-colors hover:bg-neutral-100 dark:border-neutral-600 dark:bg-neutral-900 dark:hover:bg-neutral-800">
                    {uploading ? (
                      <span className="text-xs">Uploading…</span>
                    ) : (
                      <>
                        <span className="text-2xl">📷</span>
                        <span className="text-xs font-medium capitalize">{type}</span>
                        <span className="text-xs">Tap to capture</span>
                      </>
                    )}
                    <input
                      type="file"
                      accept="image/*"
                      capture="environment"
                      className="sr-only"
                      disabled={uploading}
                      onChange={(e) => {
                        const file = e.target.files?.[0]
                        if (file) handlePhotoCapture(type, file)
                      }}
                    />
                  </label>
                )}
              </div>
            )
          })}
        </div>
      </div>

      {machine && (
        <div className="mb-4">
          <h1 className="text-xl font-semibold">{machine.official_name}</h1>
          <div className="flex items-center gap-2">
            {machine.pod_location && (
              <p className="text-sm text-neutral-500">{machine.pod_location}</p>
            )}
            <span className="text-sm text-neutral-400">
              · {doneCount}/{lines.length} dispatched
            </span>
          </div>
        </div>
      )}

      {shelves.map(([shelfCode, shelfLines], idx) => (
        <div key={shelfCode} {...(idx === 0 ? { 'data-tour': 'dispatch-lines' } : {})} className="mb-4">
          <h2 className="mb-2 text-sm font-semibold uppercase tracking-wide text-neutral-500">
            Shelf {shelfCode}
          </h2>
          <ul className="space-y-1">
            {shelfLines.map((line) => {
              const expiryStyle = getExpiryStyle(line.expiry_date)
              const isMixed = line.boonz_product_id ? mixedDateProducts.has(line.boonz_product_id) : false
              const invWarning = invWarnings[line.dispatch_id]

              return (
                <li
                  key={line.dispatch_id}
                  className="rounded-lg border border-neutral-200 bg-white p-3 dark:border-neutral-800 dark:bg-neutral-950"
                >
                  <div className="flex items-center gap-3">
                    <button
                      onClick={() => handleDispatchLine(line.dispatch_id)}
                      disabled={line.dispatched}
                      className={`flex h-6 w-6 shrink-0 items-center justify-center rounded border text-sm ${
                        line.dispatched
                          ? 'border-green-500 bg-green-100 text-green-700 dark:bg-green-900 dark:text-green-300'
                          : 'border-neutral-300 bg-white hover:bg-neutral-50 dark:border-neutral-600 dark:bg-neutral-900'
                      }`}
                    >
                      {line.dispatched ? '✓' : ''}
                    </button>

                    <div className="min-w-0 flex-1">
                      <p className="truncate text-sm font-medium">{line.pod_product_name}</p>

                      {/* Expiry from packing step */}
                      {line.expiry_date && (
                        <p className="mt-0.5 text-xs">
                          <span className="text-neutral-500">Expiry: </span>
                          <span className={expiryStyle.qtyColor}>{formatDMY(line.expiry_date)}</span>
                        </p>
                      )}

                      {/* Mixed-batch signal */}
                      {isMixed && (
                        <p className="mt-0.5 inline-flex items-center gap-1 rounded-full bg-amber-100 px-2 py-0.5 text-xs font-medium text-amber-700 dark:bg-amber-900/30 dark:text-amber-300">
                          ⚠ Mixed dates — load oldest first
                        </p>
                      )}

                      {/* Inventory warning (non-blocking) */}
                      {invWarning && (
                        <p className="mt-0.5 text-xs text-amber-600 dark:text-amber-400">{invWarning}</p>
                      )}

                      <p className="mt-0.5 text-xs text-neutral-500">Planned: {line.quantity}</p>
                    </div>

                    <input
                      type="number"
                      min={0}
                      value={line.filled_quantity}
                      onChange={(e) =>
                        updateQuantity(line.dispatch_id, parseFloat(e.target.value) || 0)
                      }
                      disabled={line.dispatched}
                      className="w-16 rounded border border-neutral-300 px-2 py-1 text-center text-sm disabled:opacity-50 dark:border-neutral-600 dark:bg-neutral-900"
                    />
                  </div>

                  <input
                    type="text"
                    value={line.comment}
                    onChange={(e) => updateComment(line.dispatch_id, e.target.value)}
                    onBlur={(e) => saveComment(line.dispatch_id, e.target.value)}
                    disabled={line.dispatched}
                    placeholder="Add note…"
                    className="mt-2 w-full rounded border border-neutral-200 px-2 py-1 text-xs text-neutral-600 placeholder:text-neutral-400 disabled:opacity-50 dark:border-neutral-700 dark:bg-neutral-900 dark:text-neutral-400"
                  />
                </li>
              )
            })}
          </ul>
        </div>
      ))}

      {!allDone && (
        <button
          onClick={handleMarkAllDispatched}
          disabled={markingAll}
          className="mt-4 w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          {markingAll ? 'Marking…' : 'Mark all dispatched'}
        </button>
      )}

      {allDone && (
        <p className="mt-4 text-center text-sm font-medium text-green-600 dark:text-green-400">
          All items dispatched ✓
        </p>
      )}
    </div>
  )
}
