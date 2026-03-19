'use client'

import { useState } from 'react'
import type { Language } from './translations'

interface LanguageOption {
  code: Language
  flag: string
  label: string
}

const LANGUAGE_OPTIONS: LanguageOption[] = [
  { code: 'en', flag: '🇬🇧', label: 'English' },
  { code: 'hi', flag: '🇮🇳', label: 'हिन्दी — Hindi' },
  { code: 'ta', flag: '🇮🇳', label: 'தமிழ் — Tamil' },
  { code: 'ml', flag: '🇮🇳', label: 'മലയാളം — Malayalam' },
  { code: 'tl', flag: '🇵🇭', label: 'Filipino' },
]

interface LanguagePickerProps {
  onComplete: (language: Language) => void
}

export default function LanguagePicker({ onComplete }: LanguagePickerProps) {
  const [selected, setSelected] = useState<Language | null>(null)

  function handleConfirm() {
    if (!selected) return
    onComplete(selected)
  }

  return (
    <div className="fixed inset-0 z-50 flex flex-col items-center justify-center bg-white px-6 dark:bg-neutral-950">
      {/* App name */}
      <p className="mb-8 text-3xl font-black tracking-tight text-neutral-900 dark:text-white">
        Boonz
      </p>

      {/* Title */}
      <h1 className="mb-1 text-xl font-bold text-neutral-900 dark:text-white">
        Choose your language
      </h1>
      <p className="mb-8 text-sm text-neutral-500">
        Select the language for your app tour
      </p>

      {/* Language buttons */}
      <div className="w-full max-w-sm space-y-3">
        {LANGUAGE_OPTIONS.map((opt) => (
          <button
            key={opt.code}
            onClick={() => setSelected(opt.code)}
            className={`flex w-full items-center gap-4 rounded-2xl border-2 px-5 py-4 text-left transition-colors ${
              selected === opt.code
                ? 'border-blue-600 bg-blue-50 dark:border-blue-500 dark:bg-blue-950'
                : 'border-neutral-200 bg-white hover:border-neutral-300 hover:bg-neutral-50 dark:border-neutral-700 dark:bg-neutral-900 dark:hover:border-neutral-600'
            }`}
          >
            <span className="text-2xl leading-none">{opt.flag}</span>
            <span
              className={`text-base font-medium ${
                selected === opt.code
                  ? 'text-blue-700 dark:text-blue-300'
                  : 'text-neutral-800 dark:text-neutral-200'
              }`}
            >
              {opt.label}
            </span>
            {selected === opt.code && (
              <span className="ml-auto text-blue-600 dark:text-blue-400">✓</span>
            )}
          </button>
        ))}
      </div>

      {/* Confirm button */}
      <div className="mt-8 w-full max-w-sm">
        <button
          onClick={handleConfirm}
          disabled={!selected}
          className="w-full rounded-2xl bg-blue-600 py-4 text-base font-semibold text-white shadow-lg transition-opacity disabled:opacity-30 hover:bg-blue-700"
        >
          Continue
        </button>
      </div>
    </div>
  )
}
