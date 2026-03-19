'use client'

import { useState, useEffect, useRef, useCallback } from 'react'
import { createClient } from '@/lib/supabase/client'
import type { Language, TourStep, PageTourId } from './translations'
import { translations } from './translations'

interface UsePageTourResult {
  showTour: boolean
  tourSteps: TourStep[]
  language: Language
  completeTour: () => void
}

export function usePageTour(pageKey: PageTourId): UsePageTourResult {
  const [showTour, setShowTour] = useState(false)
  const [language, setLanguage] = useState<Language>('en')
  const [userId, setUserId] = useState<string | null>(null)
  const [pagesToured, setPagesToured] = useState<Record<string, boolean>>({})
  const hasChecked = useRef(false)

  useEffect(() => {
    if (hasChecked.current) return
    hasChecked.current = true

    const supabase = createClient()

    async function check() {
      const { data: { user } } = await supabase.auth.getUser()
      if (!user) return

      setUserId(user.id)

      const { data: profile } = await supabase
        .from('user_profiles')
        .select('preferred_language, onboarding_complete, pages_toured')
        .eq('id', user.id)
        .single()

      if (!profile) return

      const lang = (profile.preferred_language ?? 'en') as Language
      setLanguage(lang)

      // Only show page tours after dashboard onboarding is complete
      if (!profile.onboarding_complete) return

      const toured = (profile.pages_toured ?? {}) as Record<string, boolean>
      setPagesToured(toured)

      if (!toured[pageKey]) {
        setShowTour(true)
      }
    }

    check()
  }, [pageKey])

  const completeTour = useCallback(() => {
    setShowTour(false)

    if (!userId) return

    const updated = { ...pagesToured, [pageKey]: true }
    setPagesToured(updated)

    const supabase = createClient()
    supabase
      .from('user_profiles')
      .update({ pages_toured: updated })
      .eq('id', userId)
      .then(() => {
        // silent
      })
  }, [userId, pagesToured, pageKey])

  const tourSteps = translations[language]?.pageTours?.[pageKey] ?? []

  return { showTour, tourSteps, language, completeTour }
}
