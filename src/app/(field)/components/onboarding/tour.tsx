"use client";

import { useState, useEffect, useCallback, useRef } from "react";
import type { TourStep, TooltipPosition } from "./translations";

interface TourProps {
  steps: TourStep[];
  onComplete: () => void;
  onSkip: () => void;
}

const TOOLTIP_GAP = 12;
const TOOLTIP_WIDTH = 280;
const TOOLTIP_EST_HEIGHT = 200;
const MARGIN = 16;
const SPOTLIGHT_PAD = 8;
const SPOTLIGHT_RADIUS = 12;

interface TooltipCoords {
  top: number;
  left: number;
  arrowDir: "up" | "down" | "left-arrow" | "right-arrow" | "none";
}

function computeTooltipPosition(
  rect: DOMRect,
  preferred: TooltipPosition,
  tooltipH: number,
): TooltipCoords {
  const vh = window.innerHeight;
  const vw = window.innerWidth;

  const positions: TooltipPosition[] = [
    preferred,
    "bottom",
    "top",
    "right",
    "left",
    "center",
  ];
  const arrowMap: Record<TooltipPosition, TooltipCoords["arrowDir"]> = {
    bottom: "up",
    top: "down",
    right: "left-arrow",
    left: "right-arrow",
    center: "none",
  };

  for (const pos of positions) {
    let top = 0;
    let left = 0;

    if (pos === "bottom") {
      top = rect.bottom + SPOTLIGHT_PAD + TOOLTIP_GAP;
      left = rect.left + rect.width / 2 - TOOLTIP_WIDTH / 2;
    } else if (pos === "top") {
      top = rect.top - SPOTLIGHT_PAD - tooltipH - TOOLTIP_GAP;
      left = rect.left + rect.width / 2 - TOOLTIP_WIDTH / 2;
    } else if (pos === "right") {
      top = rect.top + rect.height / 2 - tooltipH / 2;
      left = rect.right + SPOTLIGHT_PAD + TOOLTIP_GAP;
    } else if (pos === "left") {
      top = rect.top + rect.height / 2 - tooltipH / 2;
      left = rect.left - SPOTLIGHT_PAD - TOOLTIP_WIDTH - TOOLTIP_GAP;
    } else {
      // center fallback
      return {
        top: vh / 2 - tooltipH / 2,
        left: vw / 2 - TOOLTIP_WIDTH / 2,
        arrowDir: "none",
      };
    }

    // Clamp to screen edges
    top = Math.max(MARGIN, Math.min(top, vh - tooltipH - MARGIN));
    left = Math.max(MARGIN, Math.min(left, vw - TOOLTIP_WIDTH - MARGIN));

    // Check overlap with target
    const tooltipBottom = top + tooltipH;
    const tooltipRight = left + TOOLTIP_WIDTH;

    const overlapsVertically = !(
      tooltipBottom < rect.top - SPOTLIGHT_PAD ||
      top > rect.bottom + SPOTLIGHT_PAD
    );
    const overlapsHorizontally = !(
      tooltipRight < rect.left - SPOTLIGHT_PAD ||
      left > rect.right + SPOTLIGHT_PAD
    );

    if (!overlapsVertically || !overlapsHorizontally) {
      return { top, left, arrowDir: arrowMap[pos] };
    }
  }

  // Ultimate fallback
  return { top: vh - tooltipH - MARGIN, left: MARGIN, arrowDir: "none" };
}

export default function Tour({ steps, onComplete, onSkip }: TourProps) {
  const [currentStep, setCurrentStep] = useState(0);
  const [targetRect, setTargetRect] = useState<DOMRect | null>(null);
  const [tooltipCoords, setTooltipCoords] = useState<TooltipCoords | null>(
    null,
  );
  const tooltipRef = useRef<HTMLDivElement>(null);
  const measureTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);

  const step = steps[currentStep];
  const isLast = currentStep === steps.length - 1;
  const total = steps.length;

  const measure = useCallback(() => {
    if (!step) return;

    const el = document.querySelector(`[data-tour="${step.targetId}"]`);
    if (!el) {
      // Element not found — use center position
      setTargetRect(null);
      const tooltipH = tooltipRef.current?.offsetHeight ?? TOOLTIP_EST_HEIGHT;
      setTooltipCoords({
        top: window.innerHeight / 2 - tooltipH / 2,
        left: window.innerWidth / 2 - TOOLTIP_WIDTH / 2,
        arrowDir: "none",
      });
      return;
    }

    const rect = el.getBoundingClientRect();
    setTargetRect(rect);
    const tooltipH = tooltipRef.current?.offsetHeight ?? TOOLTIP_EST_HEIGHT;
    setTooltipCoords(
      computeTooltipPosition(rect, step.tooltipPosition, tooltipH),
    );
  }, [step]);

  // Scroll into view + measure on step change
  useEffect(() => {
    if (!step) return;

    const el = document.querySelector(`[data-tour="${step.targetId}"]`);
    if (el) {
      el.scrollIntoView({ behavior: "smooth", block: "center" });
    }

    // Wait for scroll to settle, then measure
    measureTimeoutRef.current = setTimeout(() => {
      measure();
      // Re-measure once more after a brief delay to account for layout shifts
      setTimeout(measure, 100);
    }, 350);

    return () => {
      if (measureTimeoutRef.current) clearTimeout(measureTimeoutRef.current);
    };
  }, [currentStep, step, measure]);

  // Handle resize
  useEffect(() => {
    window.addEventListener("resize", measure);
    return () => window.removeEventListener("resize", measure);
  }, [measure]);

  function handleNext() {
    if (isLast) {
      onComplete();
    } else {
      setCurrentStep((s) => s + 1);
    }
  }

  // Tap on target element advances tour
  function handleTargetClick() {
    handleNext();
  }

  if (!step) return null;

  const rect = targetRect;

  return (
    <>
      {/* SVG spotlight overlay */}
      <svg
        style={{
          position: "fixed",
          inset: 0,
          width: "100%",
          height: "100%",
          zIndex: 9998,
        }}
        onClick={(e) => e.stopPropagation()}
      >
        <defs>
          <mask id="spotlight-mask">
            <rect width="100%" height="100%" fill="white" />
            {rect && (
              <rect
                x={rect.left - SPOTLIGHT_PAD}
                y={rect.top - SPOTLIGHT_PAD}
                width={rect.width + SPOTLIGHT_PAD * 2}
                height={rect.height + SPOTLIGHT_PAD * 2}
                rx={SPOTLIGHT_RADIUS}
                fill="black"
              />
            )}
          </mask>
        </defs>
        {/* Dark overlay with hole */}
        <rect
          width="100%"
          height="100%"
          fill="rgba(0,0,0,0.65)"
          mask="url(#spotlight-mask)"
        />
        {/* Highlight ring */}
        {rect && (
          <rect
            x={rect.left - SPOTLIGHT_PAD}
            y={rect.top - SPOTLIGHT_PAD}
            width={rect.width + SPOTLIGHT_PAD * 2}
            height={rect.height + SPOTLIGHT_PAD * 2}
            rx={SPOTLIGHT_RADIUS}
            fill="none"
            stroke="#3B82F6"
            strokeWidth="2"
          />
        )}
      </svg>

      {/* Clickable zone over the target element — advances tour */}
      {rect && (
        <div
          onClick={handleTargetClick}
          style={{
            position: "fixed",
            left: rect.left - SPOTLIGHT_PAD,
            top: rect.top - SPOTLIGHT_PAD,
            width: rect.width + SPOTLIGHT_PAD * 2,
            height: rect.height + SPOTLIGHT_PAD * 2,
            zIndex: 9999,
            cursor: "pointer",
          }}
        />
      )}

      {/* Tooltip bubble */}
      <div
        ref={tooltipRef}
        style={{
          position: "fixed",
          zIndex: 10000,
          top: tooltipCoords?.top ?? window.innerHeight / 2 - 100,
          left:
            tooltipCoords?.left ?? window.innerWidth / 2 - TOOLTIP_WIDTH / 2,
          width: TOOLTIP_WIDTH,
          transition: "top 0.25s ease, left 0.25s ease",
        }}
        className="rounded-2xl bg-white p-4 shadow-xl dark:bg-neutral-900"
      >
        {/* Arrow */}
        {tooltipCoords?.arrowDir === "up" && (
          <div
            className="absolute -top-2 left-1/2 -translate-x-1/2"
            style={{
              width: 0,
              height: 0,
              borderLeft: "8px solid transparent",
              borderRight: "8px solid transparent",
              borderBottom: "8px solid white",
            }}
          />
        )}
        {tooltipCoords?.arrowDir === "down" && (
          <div
            className="absolute -bottom-2 left-1/2 -translate-x-1/2"
            style={{
              width: 0,
              height: 0,
              borderLeft: "8px solid transparent",
              borderRight: "8px solid transparent",
              borderTop: "8px solid white",
            }}
          />
        )}
        {tooltipCoords?.arrowDir === "left-arrow" && (
          <div
            className="absolute -left-2 top-1/2 -translate-y-1/2"
            style={{
              width: 0,
              height: 0,
              borderTop: "8px solid transparent",
              borderBottom: "8px solid transparent",
              borderRight: "8px solid white",
            }}
          />
        )}
        {tooltipCoords?.arrowDir === "right-arrow" && (
          <div
            className="absolute -right-2 top-1/2 -translate-y-1/2"
            style={{
              width: 0,
              height: 0,
              borderTop: "8px solid transparent",
              borderBottom: "8px solid transparent",
              borderLeft: "8px solid white",
            }}
          />
        )}

        {/* Step dots */}
        <div className="mb-3 flex justify-center gap-1.5">
          {steps.map((_, i) => (
            <div
              key={i}
              className={`h-2 rounded-full transition-all ${
                i <= currentStep
                  ? "w-5 bg-blue-600 dark:bg-blue-400"
                  : "w-2 bg-neutral-200 dark:bg-neutral-700"
              }`}
            />
          ))}
        </div>

        {/* Step counter */}
        <p className="mb-1 text-center text-xs text-neutral-400">
          {currentStep + 1} / {total}
        </p>

        {/* Title */}
        <h2 className="mb-1 text-center text-base font-bold text-gray-900 dark:text-white">
          {step.title}
        </h2>

        {/* Body */}
        <p className="mb-4 text-center text-sm leading-relaxed text-gray-600 dark:text-neutral-400">
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
            className={`flex-1 rounded-2xl py-3 text-sm font-semibold transition-colors ${
              isLast
                ? "bg-green-600 text-white hover:bg-green-700"
                : "bg-blue-600 text-white hover:bg-blue-700"
            }`}
          >
            {isLast ? step.buttonDone : step.buttonNext}
          </button>
        </div>
      </div>
    </>
  );
}
