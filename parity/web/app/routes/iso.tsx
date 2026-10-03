/**
 * /iso/:id — renders exactly one parity case, centred, no page chrome.
 *
 * Contract:
 *  - all transitions/animations/carets are killed via an injected style tag
 *  - `data-parity-ready="1"` lands on <body> once `document.fonts.ready` resolves
 *  - an unknown id still becomes ready, but renders `[data-parity-error]`
 */
import { useEffect } from "react"

import type { Route } from "./+types/iso"
import { getCase } from "~/parity/cases"

const KILL_MOTION =
  "*,*::before,*::after{transition:none!important;animation:none!important;caret-color:transparent!important}"

export function meta({ params }: Route.MetaArgs) {
  return [{ title: `iso/${params.id}` }]
}

export default function Iso({ params }: Route.ComponentProps) {
  const id = params.id
  const entry = getCase(id)

  useEffect(() => {
    let cancelled = false

    const mark = () => {
      if (!cancelled) {
        document.body.setAttribute("data-parity-ready", "1")
      }
    }

    if (document.fonts && typeof document.fonts.ready?.then === "function") {
      document.fonts.ready.then(mark, mark)
    } else {
      mark()
    }

    return () => {
      cancelled = true
      document.body.removeAttribute("data-parity-ready")
    }
  }, [id])

  return (
    <>
      <style dangerouslySetInnerHTML={{ __html: KILL_MOTION }} />
      <main
        data-parity-case={id}
        className="flex min-h-svh w-full items-center justify-center bg-background p-8 text-foreground"
      >
        {entry ? (
          entry.render()
        ) : (
          <div
            data-parity-error=""
            id="parity-unknown-case"
            style={{
              border: "2px solid red",
              color: "red",
              padding: "12px",
              fontFamily: "monospace",
              fontSize: "14px",
            }}
          >
            UNKNOWN PARITY CASE: {String(id)}
          </div>
        )}
      </main>
    </>
  )
}
