# Pulse Brand Kit

Canonical source of visual identity and voice for Pulse Core Next. Every LWC in the Admin Studio, Record Stepper, Conversation Hub, and Action Hub surfaces must adhere to these tokens.

## Where tokens live

| Purpose | Path |
|---|---|
| Runtime CSS (loaded into every Pulse LWC via static resource) | `force-app/main/default/staticresources/pulse_brand_tokens.css` |
| Programmatic access (JSON, W3C design-tokens format) | `docs/brand-kit/tokens.json` |
| Full visual reference (original HTML spec) | `docs/brand-kit/brand-kit.html` |

The CSS file is the deployed artifact. The JSON file is for reading tokens programmatically (e.g. a future Figma round-trip or style-dictionary build). The HTML file is the original full spec with logo-usage rules, voice guidance, and marketing copy samples.

**If any of these fall out of sync, the CSS is the tie-breaker** — it's what ships to users.

## Using tokens in LWCs

```javascript
import { LightningElement } from 'lwc';
import { loadStyle } from 'lightning/platformResourceLoader';
import TOKENS from '@salesforce/resourceUrl/pulse_brand_tokens';

export default class PulseWorkflowCanvas extends LightningElement {
    connectedCallback() {
        loadStyle(this, TOKENS + '/pulse_brand_tokens.css');
    }
}
```

Then in the LWC's own CSS, reference the CSS custom properties:

```css
:host {
    background: var(--pulse-off-white);
    color: var(--pulse-dark);
    font-family: var(--pulse-font-primary);
}

.publish-button {
    background: var(--pulse-gradient);
    color: var(--pulse-white);
    padding: var(--pulse-space-3) var(--pulse-space-6);
    border-radius: var(--pulse-radius-lg);
    box-shadow: var(--pulse-shadow-purple);
    transition: all var(--pulse-transition-base);
}
```

Or use the pre-built component classes directly in the LWC template:

```html
<button class="pulse-btn pulse-btn-primary">Publish workflow</button>
<span class="pulse-badge pulse-badge-success">Active</span>
<div class="pulse-card">...</div>
```

## Logo assets — pending

The full brand kit references three logo variants (`pulse-logo-v2.png`, `pulse-logo-full.png`, `pulse-logo-white.png`). These are **not yet in the repo**. Before the first public-facing LWC ships, drop them into `force-app/main/default/staticresources/pulse_logo_set/` as a bundle, then update each consuming LWC.

Until the real logo assets arrive, use the gradient-text `.pulse-gradient-text` treatment on the word "Pulse" as a placeholder brandmark.

## Voice of the product UI (not marketing)

The brand kit's voice guidance targets marketing copy — pipeline alerts, AppExchange listings, email nurture. In-product UI should follow the same *principles* but not copy-paste those samples:

- **Specific over generic.** Button says "Publish workflow" not "Save changes."
- **Actions, not features.** Empty state says "Author your first workflow" not "Get started with Pulse."
- **Admin respect.** Error messages identify what failed and what to do, never a generic "Something went wrong."
- **No buzzwords.** In UI copy, avoid: "synergy," "seamlessly," "empower," "unlock," "intuitive."

## Accessibility floor

The brand palette is contrast-checked for WCAG AA on the following pairings:
- `--pulse-dark` on `--pulse-white` (passes AAA)
- `--pulse-white` on `--pulse-purple` (passes AA for 14px+ bold)
- `--pulse-purple` on `--pulse-white` (passes AAA)

Do not place `--pulse-slate-light` on `--pulse-white` for body text — contrast is below AA. Reserve that color for placeholders and captions ≥12px.

## Updating tokens

1. Edit `pulse_brand_tokens.css` first (the deployed artifact).
2. Mirror changes into `docs/brand-kit/tokens.json`.
3. Update this README if a token is added, removed, or meaningfully redefined.
4. Deploy the static resource: `sf project deploy start -o pulse-core-next-dev --source-dir force-app/main/default/staticresources`.
5. Hard-refresh any open Pulse LWC surface to bypass browser cache.
