'use client'

import { useEffect, useState, useCallback } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../components/field-header'
import { usePageTour } from '../../../components/onboarding/use-page-tour'
import Tour from '../../../components/onboarding/tour'

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
  shelf_code: string
  pod_product_name: string
  quantity: number
  filled_quantity: number
  dispatched: boolean
  comment: string
}

export default function DispatchingDetailPage() {
  const params = useParams<{ machineId: string }>()
  const router = useRouter()
  const machineId = params.machineId
  const { showTour, tourSteps, completeTour } = usePageTour('dispatching')

  const [machine, setMachine] = useState<MachineInfo | null>(null)
  const [lines, setLines] = useState<DispatchLine[]>([])
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
        quantity,
        filled_quantity,
        dispatched,
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
          shelf_code: shelf.shelf_code,
          pod_product_name: product.pod_product_name,
          quantity: line.quantity ?? 0,
          filled_quantity: line.filled_quantity ?? line.quantity ?? 0,
          dispatched: !!line.dispatched,
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

  useEffect(() => {
    fetchData()
  }, [fetchData])

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

  function updateQuantity(dispatchId: string, value: number) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, filled_quantity: value } : l
      )
    )
  }

  function updateComment(dispatchId: string, value: string) {
    setLines((prev) =>
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, comment: value } : l
      )
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
      prev.map((l) =>
        l.dispatch_id === dispatchId ? { ...l, dispatched: true } : l
      )
    )
  }

  async function handleMarkAllDispatched() {
    setMarkingAll(true)
    const supabase = createClient()
    const today = new Date().toISOString().split('T')[0]

    // For unedited lines, use planned quantity
    const updates = lines
      .filter((l) => !l.dispatched)
      .map((l) =>
        supabase
          .from('refill_dispatching')
          .update({
            dispatched: true,
            filled_quantity: l.filled_quantity,
            item_added: true,
            comment: l.comment.trim() || null,
          })
          .eq('dispatch_id', l.dispatch_id)
          .eq('dispatch_date', today)
      )

    await Promise.all(updates)
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

  // Group by shelf_code
  const grouped = new Map<string, DispatchLine[]>()
  for (const line of lines) {
    const existing = grouped.get(line.shelf_code) ?? []
    existing.push(line)
    grouped.set(line.shelf_code, existing)
  }
  const shelves = Array.from(grouped.entries()).sort((a, b) =>
    a[0].localeCompare(b[0])
  )

  return (
    <div className="px-4 py-4">
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
          <h2 className="mb-2 text-sm font-semibold text-neutral-500 uppercase tracking-wide">
            Shelf {shelfCode}
          </h2>
          <ul className="space-y-1">
            {shelfLines.map((line) => (
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
                  <div className="flex-1 min-w-0">
                    <p className="text-sm font-medium truncate">
                      {line.pod_product_name}
                    </p>
                    <p className="text-xs text-neutral-500">
                      Planned: {line.quantity}
                    </p>
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
            ))}
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
