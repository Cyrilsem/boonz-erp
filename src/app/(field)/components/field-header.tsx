'use client'

import Link from 'next/link'

interface FieldHeaderProps {
  title: string
  rightAction?: React.ReactNode
}

export function FieldHeader({ title, rightAction }: FieldHeaderProps) {
  return (
    <div className="flex items-center justify-between border-b border-neutral-200 px-4 py-3 dark:border-neutral-800">
      <Link
        href="/field"
        className="text-sm text-neutral-500 hover:text-neutral-700 dark:hover:text-neutral-300"
      >
        ← Home
      </Link>
      <h1 className="text-base font-semibold">{title}</h1>
      <div className="min-w-[60px] text-right">{rightAction ?? null}</div>
    </div>
  )
}
