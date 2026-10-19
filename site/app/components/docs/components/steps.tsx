import type { ReactNode } from "react";

// The same classes remark-steps adds; their styles ship with this component.
export function Steps({ children }: { children: ReactNode }) {
  return <div className="fd-steps">{children}</div>;
}

export function Step({ children }: { children: ReactNode }) {
  return <div className="fd-step">{children}</div>;
}
