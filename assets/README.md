# Insomemo artwork

- `app-icon-original.png`: the purple artwork supplied by the user, unchanged.
- `AppIcon.png`: the same artwork with the black exterior removed; packaged into the app's multi-resolution `AppIcon.icns` by `scripts/bundle-macos.py`.
- `tray-template-source.png`: the current transparent monochrome symbol, with arrows above and below the keyboard.
- `tray-template-side-arrows-source.png`: the alternate version, with curved sync arrows on the left and right of the keyboard stack, retained for comparison.
- `TrayTemplate.png`: a 72-pixel packaging rendition of the current vertical-arrow mask, embedded in the executable and displayed on a 24-point canvas. macOS renders the template in white or dark according to the actual menu-bar appearance, including selection/high-contrast states. Separate colored tray art is not needed.

Both transparent assets were prepared with the built-in imagegen tool. The original artwork remains available above. Packaging resizes use macOS `sips`; they do not redesign the artwork.

The side-arrow revision was also prepared with the built-in imagegen tool; its edit and refinement prompts are recorded in [tray-side-arrows-prompts.txt](tray-side-arrows-prompts.txt).

App extraction prompt:

> Use case: background-extraction. Asset type: macOS application icon for Insomemo. Edit the attached artwork with exactly one change: remove the plain black background OUTSIDE the large purple rounded-square icon and make only that exterior transparent. Preserve the original purple rounded square, glossy finish, lighting, cyan and pink sync arrows, all three stacked keyboard cards, keyboard glyph, exact shapes, colors, positions, and interior dark shading. Do not redesign, simplify, flatten, add text, or change the artwork. Keep the entire rounded square centered with its existing small outer padding. Actual transparent alpha outside its perimeter, crisp clean antialiased edges.

Tray extraction prompt:

> Use case: background-extraction. Asset type: production macOS menu-bar template icon for Insomemo. Edit target: the attached reference sheet. Extract ONLY the THIRD symbol from the left (the dark monochrome keyboard stack with two circular sync arrows). Preserve that exact silhouette, arrangement, arrows, three layered rounded cards, two rows of keyboard key holes and spacebar hole. Remove everything else including the light panel background and all other icons. Output one centered solid black monochrome symbol on a genuinely transparent background, with all keyboard holes and gaps transparent. No color, gradients, shadows, glow, lettering, border, or background. Tight square canvas with 5% clear padding, large well-defined silhouette, crisp antialiased edges. This is an extraction of the supplied symbol, not a redesign.
