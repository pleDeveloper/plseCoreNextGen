import { loadStyle } from 'lightning/platformResourceLoader';
import FONTS from '@salesforce/resourceUrl/pulse_poppins_fonts';
import TOKENS from '@salesforce/resourceUrl/pulse_brand_tokens';

let loadPromise;

/**
 * Loads Pulse brand tokens (CSS custom properties) and Poppins font faces
 * into the given LWC's shadow root. Cached after the first call — safe to
 * invoke from every component's connectedCallback without duplicate loads.
 */
export function loadPulseBrandTokens(cmp) {
    if (!loadPromise) {
        loadPromise = Promise.all([
            loadStyle(cmp, FONTS + '/fonts.css'),
            loadStyle(cmp, TOKENS),
        ]);
    }
    return loadPromise;
}
