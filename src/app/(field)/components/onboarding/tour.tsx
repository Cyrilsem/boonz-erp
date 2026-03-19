'use client'

import { useState } from 'react'
import type { TourStep } from './translations'

interface TourOverlayProps {
  steps: TourStep[]
  onComplete: () => void
  onSkip: () => void
}

export default function TourOverlay({ steps, onComplete, onSkip }: TourOverlayProps) {
  const [currentStep, setCurrentStep] = useState(0)

  const step = steps[currentStep]
  const isLast = currentStep === steps.length - 1
  const total = steps.length

  function handleNext() {
    if (isLast) {
      onComplete()
    } else {
      setCurrentStep((s) => s + 1)
    }
  }

  if (!step) return null

  return (
    <div className="fixed inset-0 z-50 flex flex-col justify-end">
      {/* Backdrop — tapping it does nothing (intentional: prevent accidental dismissal) */}
      <div className="absolute inset-0 bg-black/60" />

      {/* Bottom sheet */}
      <div className="relative z-10 rounded-t-3xl bg-white px-5 pb-10 pt-5 shadow-2xl dark:bg-neutral-900">
        {/* Step dots */}
        <div className="mb-4 flex justify-center gap-1.5">
          {steps.map((_, i) => (
            <div
              key={i}
              className={`h-2 rounded-full transition-all ${
                i <= currentStep
                  ? 'w-5 bg-blue-600 dark:bg-blue-400'
                  : 'w-2 bg-neutral-200 dark:bg-neutral-700'
              }`}
            />
          ))}
        </div>

        {/* Step counter */}
        <p className="mb-2 text-center text-xs text-neutral-400">
          Step {currentStep + 1} of {total}
        </p>

        {/* Title */}
        <h2 className="mb-3 text-center text-xl font-bold leading-snug text-neutral-900 dark:text-white">
          {step.title}
        </h2>

        {/* Body */}
        <p className="mb-8 text-center text-sm leading-relaxed text-neutral-600 dark:text-neutral-400">
          {step.body}
        </p>

        {/* Buttons */}
        <div className="flex items-center justify-between gap-3">
          <button
            onClick={onSkip}
            className="text-sm text-neutral-400 underline underline-offset-2 hover:text-neutral-600 dark:text-neutral-500 dark:hover:text-neutral-300"
          >
            {step.buttonSkip}
          </button>

          <button
            onClick={handleNext}
            className={`flex-1 rounded-2xl py-3.5 text-sm font-semibold transition-colors ${
              isLast
                ? 'bg-green-600 text-white hover:bg-green-700'
                : 'bg-blue-600 text-white hover:bg-blue-700'
            }`}
          >
            {isLast ? step.buttonDone : step.buttonNext}
          </button>
        </div>
      </div>
    </div>
  )
}
