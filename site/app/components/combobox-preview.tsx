import {
  Combobox,
  ComboboxContent,
  ComboboxEmpty,
  ComboboxInput,
  ComboboxItem,
  ComboboxList,
} from "~/components/ui/combobox";

const FRAMEWORKS = ["Next.js", "React Router", "Astro", "SvelteKit", "Nuxt"];

export function ComboboxPreview() {
  return (
    <div className="w-full max-w-xs">
      <Combobox items={FRAMEWORKS}>
        <ComboboxInput placeholder="Pick a framework…" />
        <ComboboxContent>
          <ComboboxEmpty>No framework found.</ComboboxEmpty>
          <ComboboxList>
            {(item: string) => (
              <ComboboxItem key={item} value={item}>
                {item}
              </ComboboxItem>
            )}
          </ComboboxList>
        </ComboboxContent>
      </Combobox>
    </div>
  );
}
