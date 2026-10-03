# shadcn/ui parity report

Browser (Chromium, shadcn Base UI) vs palmy (Odin, software rasterizer, Wayland).
Both sides use the same four static Geist TTFs with kerning and ligatures off.

- cases captured from the browser: **182**
- cases rendered by palmy: **182**
- not implemented yet: **0**
- mean absolute error across implemented cases: **2.953/255**
- mean share of pixels within 2/255: **90.40%**
- size mismatches (layout wrong, not just antialiasing): **0**

A mean absolute error of 0 is not reachable: Chromium rasterises glyphs through
FreeType with its own hinting and gamma, palmy uses stb_truetype with grayscale
coverage. Geometry, colour and layout can match exactly, and the size column is
where that is visible.

## Per case, best first

| case | size | mae | within 2/255 | within 8/255 | worst row |
| --- | --- | --- | --- | --- | --- |
| `separator-horizontal` | 1216x2 | 0.000 | 100.00% | 100.00% | 0 |
| `separator-vertical` | 2x64 | 0.000 | 100.00% | 100.00% | 0 |
| `aspect-ratio-16-9` | 320x180 | 0.002 | 99.98% | 100.00% | 179 |
| `aspect-ratio-1-1` | 192x192 | 0.003 | 99.98% | 100.00% | 191 |
| `skeleton-default` | 256x16 | 0.007 | 100.00% | 100.00% | 2 |
| `resizable-vertical` | 1216x4 | 0.012 | 99.75% | 100.00% | 1 |
| `slider-default` | 1216x4 | 0.034 | 99.63% | 99.84% | 3 |
| `skeleton-circle` | 40x40 | 0.046 | 100.00% | 100.00% | 0 |
| `slider-range` | 1216x4 | 0.060 | 99.34% | 99.92% | 3 |
| `chart-line` | 380x220 | 0.130 | 98.97% | 99.60% | 197 |
| `direction-rtl` | 1216x4 | 0.178 | 99.42% | 99.42% | 0 |
| `sheet-right` | 384x800 | 0.253 | 99.43% | 99.54% | 33 |
| `drawer-right` | 384x800 | 0.266 | 99.39% | 99.50% | 33 |
| `input-group-textarea` | 288x104 | 0.279 | 98.23% | 98.91% | 19 |
| `chart-bar` | 380x220 | 0.303 | 98.44% | 98.94% | 205 |
| `carousel-default` | 288x44 | 0.325 | 98.24% | 99.00% | 23 |
| `sidebar-submenu` | 256x288 | 0.330 | 98.70% | 98.97% | 92 |
| `resizable-horizontal` | 1216x38 | 0.345 | 98.82% | 99.13% | 20 |
| `sheet-bottom` | 1280x159 | 0.379 | 99.13% | 99.30% | 34 |
| `empty-icon` | 1216x150 | 0.436 | 96.64% | 97.10% | 148 |
| `slider-vertical` | 4x160 | 0.461 | 96.25% | 97.19% | 90 |
| `textarea-default` | 288x64 | 0.491 | 97.49% | 98.40% | 19 |
| `textarea-disabled` | 288x64 | 0.491 | 97.31% | 98.35% | 23 |
| `progress-default` | 288x4 | 0.535 | 99.13% | 99.13% | 0 |
| `checkbox-default@hover` | 16x16 | 0.563 | 87.50% | 100.00% | 1 |
| `checkbox-default` | 16x16 | 0.563 | 87.50% | 100.00% | 1 |
| `pagination-default` | 1216x32 | 0.566 | 97.81% | 98.40% | 14 |
| `input-group-icon` | 288x32 | 0.581 | 95.76% | 97.59% | 19 |
| `input-disabled` | 288x32 | 0.601 | 96.57% | 98.09% | 20 |
| `drawer-bottom` | 1280x111 | 0.612 | 98.62% | 98.86% | 34 |
| `sidebar-default` | 256x384 | 0.632 | 98.00% | 98.25% | 152 |
| `questionnaire-input` | 384x118 | 0.696 | 97.13% | 97.85% | 9 |
| `accordion-closed` | 320x86 | 0.733 | 97.53% | 98.01% | 20 |
| `questionnaire-choices` | 384x324 | 0.747 | 96.94% | 97.70% | 41 |
| `kbd-default` | 20x20 | 0.805 | 93.50% | 95.00% | 5 |
| `toast-default` | 384x78 | 0.824 | 95.51% | 96.97% | 54 |
| `input-placeholder` | 288x32 | 0.844 | 93.93% | 96.44% | 19 |
| `empty-default` | 1216x146 | 0.855 | 96.14% | 96.50% | 1 |
| `switch-off@hover` | 32x20 | 0.863 | 85.63% | 100.00% | 0 |
| `switch-off` | 32x20 | 0.863 | 85.63% | 100.00% | 0 |
| `input-invalid` | 288x32 | 0.894 | 96.67% | 97.33% | 17 |
| `table-footer` | 480x188 | 0.922 | 96.74% | 97.25% | 19 |
| `marker-border` | 288x30 | 0.931 | 93.65% | 95.61% | 14 |
| `collapsible-closed` | 288x32 | 0.961 | 96.17% | 97.45% | 14 |
| `field-group` | 320x164 | 0.982 | 94.80% | 98.05% | 118 |
| `message-start` | 320x68 | 1.002 | 96.24% | 96.93% | 50 |
| `combobox-open` | 223x120 | 1.013 | 96.12% | 97.00% | 45 |
| `attachment-vertical` | 120x164 | 1.017 | 95.26% | 96.42% | 125 |
| `message-scroller-default` | 320x192 | 1.023 | 96.74% | 97.24% | 64 |
| `avatar-lg` | 40x40 | 1.029 | 93.81% | 96.44% | 17 |
| `combobox-empty` | 223x36 | 1.039 | 94.32% | 96.34% | 21 |
| `bubble-secondary` | 256x42 | 1.053 | 96.22% | 96.78% | 22 |
| `accordion-default` | 320x116 | 1.068 | 96.50% | 97.11% | 51 |
| `select-open` | 224x125 | 1.140 | 96.30% | 97.13% | 68 |
| `input-group-button` | 288x32 | 1.169 | 93.42% | 95.65% | 19 |
| `toggle-group-default` | 124x32 | 1.172 | 95.59% | 96.50% | 16 |
| `select-trigger-sm` | 224x28 | 1.181 | 93.72% | 95.76% | 12 |
| `scroll-area-default` | 256x160 | 1.204 | 95.94% | 96.67% | 80 |
| `select-trigger` | 224x32 | 1.224 | 94.78% | 96.75% | 15 |
| `popover-header` | 288x104 | 1.233 | 94.24% | 95.82% | 45 |
| `accordion-multiple` | 320x146 | 1.246 | 95.87% | 96.55% | 124 |
| `alert-default` | 384x60 | 1.260 | 93.97% | 95.74% | 44 |
| `toggle-group-vertical` | 36x72 | 1.266 | 95.53% | 96.53% | 16 |
| `item-muted` | 320x68 | 1.282 | 96.74% | 97.19% | 50 |
| `command-dialog` | 384x145 | 1.310 | 93.04% | 96.43% | 0 |
| `bubble-outline` | 256x42 | 1.319 | 94.66% | 96.31% | 22 |
| `dropdown-menu-open` | 192x125 | 1.370 | 94.00% | 95.38% | 69 |
| `alert-destructive` | 384x60 | 1.390 | 93.59% | 94.78% | 45 |
| `input-default` | 288x32 | 1.413 | 94.10% | 95.75% | 19 |
| `item-default` | 320x68 | 1.462 | 96.15% | 96.77% | 50 |
| `table-default` | 480x152 | 1.470 | 95.39% | 96.03% | 24 |
| `alert-with-icon` | 384x60 | 1.499 | 92.83% | 94.79% | 19 |
| `input-placeholder@typed` | 288x32 | 1.508 | 96.53% | 97.18% | 16 |
| `input-otp-separator` | 208x32 | 1.522 | 93.31% | 95.36% | 15 |
| `navigation-menu-open` | 225x80 | 1.537 | 94.61% | 95.51% | 56 |
| `marker-separator` | 288x20 | 1.539 | 88.75% | 89.91% | 10 |
| `attachment-xs` | 160x38 | 1.540 | 92.12% | 94.89% | 17 |
| `item-outline` | 320x68 | 1.565 | 90.45% | 96.89% | 50 |
| `progress-label` | 288x36 | 1.568 | 94.23% | 95.44% | 8 |
| `bubble-group` | 288x90 | 1.603 | 95.14% | 95.84% | 21 |
| `dropdown-menu-radio` | 192x92 | 1.612 | 95.39% | 96.42% | 16 |
| `input-group-text` | 288x32 | 1.644 | 91.17% | 93.75% | 19 |
| `toast-action` | 384x78 | 1.650 | 94.09% | 95.79% | 43 |
| `collapsible-open` | 288x60 | 1.652 | 94.14% | 95.34% | 51 |
| `tabs-vertical` | 384x58 | 1.690 | 93.56% | 95.17% | 14 |
| `tabs-default` | 384x60 | 1.725 | 93.09% | 94.97% | 48 |
| `radio-group-default` | 288x48 | 1.737 | 96.48% | 97.04% | 35 |
| `radio-group-disabled` | 288x48 | 1.737 | 96.48% | 97.04% | 35 |
| `context-menu-open` | 144x125 | 1.762 | 91.95% | 93.79% | 74 |
| `switch-off@focus` | 32x20 | 1.766 | 79.69% | 92.66% | 1 |
| `field-set` | 320x122 | 1.778 | 92.59% | 96.64% | 18 |
| `input-placeholder@focus` | 288x32 | 1.794 | 93.39% | 94.82% | 19 |
| `dropdown-menu-checkbox` | 192x116 | 1.834 | 95.10% | 96.14% | 40 |
| `input-otp-default` | 192x32 | 1.852 | 93.13% | 94.78% | 11 |
| `calendar-dropdown` | 212x260 | 1.879 | 93.18% | 94.41% | 197 |
| `calendar-default` | 212x260 | 1.908 | 93.12% | 94.35% | 197 |
| `calendar-range` | 212x260 | 1.955 | 93.07% | 94.30% | 197 |
| `checkbox-default@focus` | 16x16 | 1.984 | 82.81% | 85.94% | 1 |
| `dialog-default` | 384x124 | 1.986 | 94.17% | 95.25% | 29 |
| `combobox-chips` | 288x32 | 2.007 | 89.45% | 94.30% | 18 |
| `message-end` | 320x68 | 2.063 | 95.49% | 96.13% | 18 |
| `command-default` | 320x214 | 2.077 | 92.05% | 95.43% | 93 |
| `menubar-open` | 144x101 | 2.091 | 92.56% | 94.00% | 47 |
| `avatar-group` | 104x32 | 2.095 | 83.32% | 93.00% | 19 |
| `hover-card-open` | 256x60 | 2.099 | 91.24% | 93.50% | 21 |
| `kbd-group` | 94x20 | 2.155 | 82.13% | 89.57% | 7 |
| `attachment-error` | 160x58 | 2.197 | 89.84% | 92.75% | 17 |
| `toggle-pressed` | 36x32 | 2.200 | 93.32% | 94.44% | 16 |
| `toggle-default` | 36x32 | 2.237 | 93.75% | 94.44% | 16 |
| `toggle-outline` | 38x32 | 2.279 | 85.69% | 93.01% | 15 |
| `attachment-default` | 166x58 | 2.288 | 89.61% | 93.58% | 17 |
| `bubble-default` | 256x42 | 2.288 | 95.34% | 95.85% | 24 |
| `button-icon` | 32x32 | 2.366 | 87.99% | 95.31% | 15 |
| `toggle-group-outline` | 68x32 | 2.389 | 84.56% | 89.38% | 15 |
| `avatar-default` | 32x32 | 2.453 | 78.91% | 91.99% | 19 |
| `context-menu-checkbox` | 144x101 | 2.539 | 91.94% | 93.82% | 16 |
| `marker-default` | 288x20 | 2.670 | 85.69% | 89.29% | 13 |
| `attachment-sm` | 160x48 | 2.840 | 90.74% | 93.91% | 36 |
| `field-vertical` | 320x90 | 2.849 | 88.25% | 93.98% | 83 |
| `avatar-badge` | 32x32 | 2.862 | 77.15% | 90.23% | 19 |
| `card-default` | 320x114 | 2.930 | 92.87% | 94.30% | 25 |
| `spinner-lg` | 32x32 | 2.996 | 86.82% | 89.65% | 26 |
| `card-footer` | 320x176 | 2.997 | 94.27% | 95.23% | 26 |
| `popover-default` | 288x40 | 3.030 | 89.26% | 91.25% | 21 |
| `navigation-menu-closed` | 196x36 | 3.135 | 89.67% | 91.51% | 16 |
| `card-sm` | 288x100 | 3.292 | 89.59% | 93.15% | 19 |
| `checkbox-indeterminate` | 16x16 | 3.336 | 74.22% | 90.63% | 8 |
| `dialog-footer` | 384x142 | 3.379 | 90.86% | 92.46% | 55 |
| `item-xs` | 320x56 | 3.397 | 88.80% | 89.59% | 23 |
| `alert-dialog-default` | 384x148 | 3.606 | 90.56% | 92.15% | 61 |
| `alert-dialog-sm` | 320x148 | 3.650 | 90.45% | 92.16% | 120 |
| `alert-dialog-media` | 384x148 | 3.680 | 90.72% | 92.23% | 61 |
| `input-default@focus` | 288x32 | 3.709 | 92.99% | 93.98% | 19 |
| `button-group-vertical` | 72x96 | 3.755 | 87.53% | 90.22% | 64 |
| `native-select-sm` | 108x28 | 3.765 | 86.94% | 89.29% | 14 |
| `button-icon-sm` | 28x28 | 3.799 | 86.99% | 87.63% | 18 |
| `button-disabled` | 68x32 | 3.877 | 84.33% | 86.81% | 20 |
| `native-select-default` | 94x32 | 3.979 | 84.61% | 88.00% | 14 |
| `button-destructive` | 68x32 | 4.010 | 85.29% | 88.83% | 20 |
| `toggle-lg` | 54x36 | 4.138 | 81.79% | 90.23% | 17 |
| `button-secondary` | 68x32 | 4.159 | 88.69% | 89.84% | 19 |
| `switch-disabled` | 32x20 | 4.202 | 79.53% | 83.75% | 0 |
| `button-group-horizontal` | 174x32 | 4.210 | 82.80% | 87.43% | 14 |
| `breadcrumb-default` | 168x20 | 4.211 | 80.33% | 85.27% | 13 |
| `badge-secondary` | 56x20 | 4.288 | 77.05% | 85.89% | 9 |
| `field-error` | 320x88 | 4.325 | 88.54% | 89.14% | 58 |
| `button-link` | 68x32 | 4.339 | 88.47% | 89.80% | 19 |
| `badge-link` | 56x20 | 4.372 | 79.91% | 85.63% | 9 |
| `menubar-closed` | 132x32 | 4.395 | 85.49% | 88.05% | 16 |
| `breadcrumb-ellipsis` | 156x20 | 4.418 | 82.98% | 85.35% | 9 |
| `badge-destructive` | 56x20 | 4.438 | 73.93% | 81.43% | 12 |
| `switch-sm` | 24x14 | 4.521 | 75.59% | 78.87% | 1 |
| `field-horizontal` | 320x44 | 4.666 | 89.26% | 91.36% | 15 |
| `button-destructive@hover` | 68x32 | 4.718 | 84.10% | 86.12% | 15 |
| `tabs-line` | 384x60 | 4.740 | 93.02% | 94.16% | 33 |
| `button-ghost` | 68x32 | 4.815 | 88.05% | 89.29% | 20 |
| `avatar-sm` | 24x24 | 4.960 | 77.26% | 85.59% | 14 |
| `button-group-text` | 190x32 | 4.999 | 83.62% | 87.42% | 14 |
| `button-outline` | 68x32 | 5.002 | 85.62% | 89.29% | 20 |
| `badge-ghost` | 56x20 | 5.084 | 79.91% | 83.30% | 12 |
| `badge-outline` | 56x20 | 5.790 | 69.55% | 80.63% | 12 |
| `button-lg` | 68x36 | 6.422 | 85.74% | 87.58% | 15 |
| `button-default` | 68x32 | 7.151 | 84.33% | 86.40% | 13 |
| `button-default@hover` | 68x32 | 7.371 | 84.65% | 86.03% | 19 |
| `tooltip-kbd` | 72x32 | 7.421 | 85.33% | 86.72% | 13 |
| `button-ghost@hover` | 68x32 | 7.616 | 86.31% | 87.36% | 15 |
| `switch-on` | 32x20 | 7.655 | 78.28% | 80.16% | 0 |
| `button-with-icon` | 77x32 | 7.719 | 85.02% | 87.22% | 13 |
| `button-outline@hover` | 68x32 | 7.749 | 83.73% | 87.18% | 15 |
| `button-secondary@hover` | 68x32 | 8.136 | 85.29% | 87.64% | 15 |
| `spinner-default` | 16x16 | 8.832 | 70.70% | 75.78% | 13 |
| `badge-notification` | 42x20 | 9.258 | 80.83% | 85.95% | 6 |
| `button-default@focus` | 68x32 | 9.464 | 82.03% | 85.66% | 19 |
| `button-xs` | 58x24 | 9.881 | 80.10% | 82.04% | 14 |
| `tooltip-default` | 100x28 | 10.584 | 83.36% | 84.43% | 11 |
| `label-default` | 94x14 | 11.040 | 61.17% | 66.94% | 5 |
| `toggle-sm` | 48x28 | 13.402 | 85.05% | 86.23% | 18 |
| `checkbox-checked` | 16x16 | 13.516 | 75.78% | 78.52% | 7 |
| `checkbox-disabled` | 16x16 | 13.516 | 75.78% | 78.52% | 7 |
| `button-sm` | 64x28 | 14.345 | 81.31% | 82.37% | 18 |
| `badge-default` | 56x20 | 15.256 | 72.68% | 74.73% | 7 |
| `badge-icon` | 80x20 | 24.364 | 71.63% | 73.63% | 9 |

## By component

| component | cases | implemented | mean mae |
| --- | --- | --- | --- |
| accordion | 3 | 3 | 1.016 |
| alert | 6 | 6 | 2.514 |
| aspect | 2 | 2 | 0.002 |
| attachment | 5 | 5 | 1.976 |
| avatar | 5 | 5 | 2.680 |
| badge | 8 | 8 | 9.106 |
| breadcrumb | 2 | 2 | 4.315 |
| bubble | 4 | 4 | 1.566 |
| button | 22 | 22 | 6.177 |
| calendar | 3 | 3 | 1.914 |
| card | 3 | 3 | 3.073 |
| carousel | 1 | 1 | 0.325 |
| chart | 2 | 2 | 0.217 |
| checkbox | 6 | 6 | 5.579 |
| collapsible | 2 | 2 | 1.307 |
| combobox | 3 | 3 | 1.353 |
| command | 2 | 2 | 1.694 |
| context | 2 | 2 | 2.150 |
| dialog | 2 | 2 | 2.682 |
| direction | 1 | 1 | 0.178 |
| drawer | 2 | 2 | 0.439 |
| dropdown | 3 | 3 | 1.605 |
| empty | 2 | 2 | 0.646 |
| field | 5 | 5 | 2.920 |
| hover | 1 | 1 | 2.099 |
| input | 13 | 13 | 1.370 |
| item | 4 | 4 | 1.926 |
| kbd | 2 | 2 | 1.480 |
| label | 1 | 1 | 11.040 |
| marker | 3 | 3 | 1.713 |
| menubar | 2 | 2 | 3.243 |
| message | 3 | 3 | 1.363 |
| native | 2 | 2 | 3.872 |
| navigation | 2 | 2 | 2.336 |
| pagination | 1 | 1 | 0.566 |
| popover | 2 | 2 | 2.131 |
| progress | 2 | 2 | 1.051 |
| questionnaire | 2 | 2 | 0.721 |
| radio | 2 | 2 | 1.737 |
| resizable | 2 | 2 | 0.179 |
| scroll | 1 | 1 | 1.204 |
| select | 3 | 3 | 1.182 |
| separator | 2 | 2 | 0.000 |
| sheet | 2 | 2 | 0.316 |
| sidebar | 2 | 2 | 0.481 |
| skeleton | 2 | 2 | 0.027 |
| slider | 3 | 3 | 0.185 |
| spinner | 2 | 2 | 5.914 |
| switch | 6 | 6 | 3.311 |
| table | 2 | 2 | 1.196 |
| tabs | 3 | 3 | 2.718 |
| textarea | 2 | 2 | 0.491 |
| toast | 2 | 2 | 1.237 |
| toggle | 8 | 8 | 3.635 |
| tooltip | 2 | 2 | 9.003 |
