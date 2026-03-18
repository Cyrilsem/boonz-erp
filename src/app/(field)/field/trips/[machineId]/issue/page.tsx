'use client'

import { useEffect, useState, useRef } from 'react'
import { useParams, useRouter } from 'next/navigation'
import { createClient } from '@/lib/supabase/client'
import { FieldHeader } from '../../../../components/field-header'

const ISSUE_TYPES = ['Hardware', 'Payment terminal', 'Display', 'Other']

export default function IssuePage() {
  const params = useParams<{ machineId: string }>()
  const router = useRouter()
  const machineId = params.machineId
  const fileInputRef = useRef<HTMLInputElement>(null)

  const [machineName, setMachineName] = useState('')
  const [issueType, setIssueType] = useState('Hardware')
  const [description, setDescription] = useState('')
  const [photoFile, setPhotoFile] = useState<File | null>(null)
  const [photoPreview, setPhotoPreview] = useState<string | null>(null)
  const [submitting, setSubmitting] = useState(false)
  const [submitted, setSubmitted] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    async function fetchMachine() {
      const supabase = createClient()
      const { data } = await supabase
        .from('machines')
        .select('official_name')
        .eq('machine_id', machineId)
        .single()

      if (data) setMachineName(data.official_name)
    }
    fetchMachine()
  }, [machineId])

  function handlePhotoChange(e: React.ChangeEvent<HTMLInputElement>) {
    const file = e.target.files?.[0]
    if (!file) return
    setPhotoFile(file)
    const url = URL.createObjectURL(file)
    setPhotoPreview(url)
  }

  async function compressImage(file: File): Promise<Blob> {
    return new Promise((resolve) => {
      const img = new Image()
      img.onload = () => {
        const canvas = document.createElement('canvas')
        let width = img.width
        let height = img.height

        // Scale down if larger than 1200px on longest side
        const MAX_DIM = 1200
        if (width > MAX_DIM || height > MAX_DIM) {
          if (width > height) {
            height = Math.round((height * MAX_DIM) / width)
            width = MAX_DIM
          } else {
            width = Math.round((width * MAX_DIM) / height)
            height = MAX_DIM
          }
        }

        canvas.width = width
        canvas.height = height
        const ctx = canvas.getContext('2d')
        ctx?.drawImage(img, 0, 0, width, height)

        canvas.toBlob(
          (blob) => resolve(blob ?? new Blob()),
          'image/jpeg',
          0.7
        )
      }
      img.src = URL.createObjectURL(file)
    })
  }

  async function handleSubmit(e: React.FormEvent) {
    e.preventDefault()
    if (!description.trim()) {
      setError('Please add a description')
      return
    }

    setSubmitting(true)
    setError(null)

    const supabase = createClient()
    const { data: { user } } = await supabase.auth.getUser()

    if (!user) {
      setError('Not authenticated')
      setSubmitting(false)
      return
    }

    let photoPath: string | null = null

    if (photoFile) {
      const compressed = await compressImage(photoFile)
      const timestamp = Date.now()
      const path = `machine-issues/${machineId}/${timestamp}.jpg`

      const { error: uploadError } = await supabase.storage
        .from('machine-issues')
        .upload(path, compressed, {
          contentType: 'image/jpeg',
          upsert: false,
        })

      if (!uploadError) {
        photoPath = path
      }
    }

    const { error: insertError } = await supabase
      .from('machine_issues')
      .insert({
        machine_id: machineId,
        reporter_user_id: user.id,
        issue_type: issueType,
        description: description.trim(),
        photo_storage_path: photoPath,
        status: 'open',
      })

    if (insertError) {
      setError('Failed to submit issue. Please try again.')
      setSubmitting(false)
      return
    }

    setSubmitted(true)
    setSubmitting(false)
  }

  if (submitted) {
    return (
      <div className="flex flex-col items-center justify-center p-8 text-center">
        <div className="mb-4 rounded-full bg-green-100 p-4 dark:bg-green-900">
          <span className="text-2xl">✓</span>
        </div>
        <h2 className="mb-2 text-lg font-semibold">Issue reported</h2>
        <p className="mb-4 text-sm text-neutral-500">
          The issue has been logged for {machineName}
        </p>
        <button
          onClick={() => router.back()}
          className="rounded-lg bg-neutral-900 px-6 py-2.5 text-sm font-medium text-white transition-colors hover:bg-neutral-800 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          Back to machine
        </button>
      </div>
    )
  }

  return (
    <div className="px-4 py-4">
      <FieldHeader title="Report Issue" />
      <p className="mb-4 text-sm text-neutral-500">{machineName}</p>

      <form onSubmit={handleSubmit} className="space-y-4">
        <div>
          <label className="mb-1 block text-sm font-medium">Issue type</label>
          <select
            value={issueType}
            onChange={(e) => setIssueType(e.target.value)}
            className="w-full rounded-lg border border-neutral-300 px-3 py-2.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          >
            {ISSUE_TYPES.map((t) => (
              <option key={t} value={t}>
                {t}
              </option>
            ))}
          </select>
        </div>

        <div>
          <label className="mb-1 block text-sm font-medium">Description</label>
          <textarea
            value={description}
            onChange={(e) => setDescription(e.target.value)}
            rows={4}
            placeholder="Describe the issue…"
            className="w-full rounded-lg border border-neutral-300 px-3 py-2.5 text-sm dark:border-neutral-600 dark:bg-neutral-900"
          />
        </div>

        <div>
          <label className="mb-1 block text-sm font-medium">Photo (optional)</label>
          <input
            ref={fileInputRef}
            type="file"
            accept="image/*"
            capture="environment"
            onChange={handlePhotoChange}
            className="hidden"
          />
          <button
            type="button"
            onClick={() => fileInputRef.current?.click()}
            className="w-full rounded-lg border border-dashed border-neutral-300 py-3 text-sm text-neutral-500 transition-colors hover:bg-neutral-50 dark:border-neutral-600 dark:hover:bg-neutral-900"
          >
            {photoFile ? photoFile.name : 'Take or choose photo'}
          </button>
          {photoPreview && (
            <img
              src={photoPreview}
              alt="Preview"
              className="mt-2 h-32 w-auto rounded-lg object-cover"
            />
          )}
        </div>

        {error && (
          <p className="text-sm text-red-600 dark:text-red-400">{error}</p>
        )}

        <button
          type="submit"
          disabled={submitting}
          className="w-full rounded-lg bg-neutral-900 py-3 text-sm font-medium text-white transition-colors hover:bg-neutral-800 disabled:opacity-50 dark:bg-neutral-100 dark:text-neutral-900 dark:hover:bg-neutral-200"
        >
          {submitting ? 'Submitting…' : 'Submit issue'}
        </button>
      </form>
    </div>
  )
}
