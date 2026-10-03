/** /parity/cases.json — the flat case index the harness drives off. */
import { caseIndex } from "~/parity/cases"

export function loader() {
  return new Response(JSON.stringify(caseIndex()), {
    headers: {
      "content-type": "application/json; charset=utf-8",
      "cache-control": "no-store",
    },
  })
}
