'use client'

import Link from 'next/link'
import { usePathname } from 'next/navigation'

interface FieldHeaderProps {
  title: string
  rightAction?: React.ReactNode
}

function getBackPath(pathname: string): string | null {
  // Home — no back button
  if (pathname === '/field') return null

  // Level 3: /field/trips/[id]/issue or /field/trips/[id]/removals
  const tripSubMatch = pathname.match(/^\/field\/trips\/([^/]+)\/(issue|removals)$/)
  if (tripSubMatch) return `/field/trips/${tripSubMatch[1]}`

  // Level 2: pages with a parent section
  const level2Patterns: { regex: RegExp; parent: string }[] = [
    { regex: /^\/field\/packing\/[^/]+$/, parent: '/field/packing' },
    { regex: /^\/field\/inventory\/[^/]+$/, parent: '/field/inventory' },
    { regex: /^\/field\/receiving\/[^/]+$/, parent: '/field/receiving' },
    { regex: /^\/field\/dispatching\/[^/]+$/, parent: '/field/dispatching' },
    { regex: /^\/field\/trips\/[^/]+$/, parent: '/field/trips' },
    { regex: /^\/field\/orders\/new$/, parent: '/field/orders' },
  ]
  for (const p of level2Patterns) {
    if (p.regex.test(pathname)) return p.parent
  }

  // Level 1: everything else goes home
  return '/field'
}

export function FieldHeader({ title, rightAction }: FieldHeaderProps) {
  const pathname = usePathname()
  const backPath = getBackPath(pathname)

  return (
    <div className="flex items-center justify-between border-b border-neutral-200 px-4 py-3 dark:border-neutral-800">
      <div className="min-w-[60px]">
        {backPath && (
          <Link
            href={backPath}
            className="text-sm text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
          >
            ← Back
          </Link>
        )}
      </div>
      <h1 className="text-base font-semibold">{title}</h1>
      <div className="min-w-[60px] text-right">{rightAction ?? null}</div>
    </div>
  )
}
