/** /parity — plain index of every case, for eyeballing. */
import { Link } from "react-router"

import { CASES } from "~/parity/cases"

export function meta() {
  return [{ title: `parity cases (${CASES.length})` }]
}

export default function ParityIndex() {
  const byComponent = new Map<string, typeof CASES>()
  for (const entry of CASES) {
    const list = byComponent.get(entry.component)
    if (list) {
      list.push(entry)
    } else {
      byComponent.set(entry.component, [entry])
    }
  }

  return (
    <main className="mx-auto flex max-w-3xl flex-col gap-6 p-8 font-mono text-sm">
      <header className="flex flex-col gap-1">
        <h1 className="text-lg font-medium">Parity cases</h1>
        <p className="text-muted-foreground">
          {CASES.length} cases across {byComponent.size} components.{" "}
          <a className="underline" href="/parity/cases.json">
            cases.json
          </a>
        </p>
      </header>
      {[...byComponent.entries()].map(([component, list]) => (
        <section key={component} className="flex flex-col gap-1">
          <h2 className="font-medium">{component}</h2>
          <ul className="flex flex-col gap-0.5 pl-4">
            {list.map((entry) => (
              <li key={entry.id}>
                <Link className="underline" to={`/iso/${entry.id}`}>
                  {entry.id}
                </Link>
                <span className="text-muted-foreground"> — {entry.title}</span>
              </li>
            ))}
          </ul>
        </section>
      ))}
    </main>
  )
}
