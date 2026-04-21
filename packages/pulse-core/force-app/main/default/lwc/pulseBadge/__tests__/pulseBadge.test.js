import { createElement } from 'lwc';
import PulseBadge from 'c/pulseBadge';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

function createComponent(props = {}) {
    const el = createElement('c-pulse-badge', { is: PulseBadge });
    Object.assign(el, { label: 'Active', ...props });
    document.body.appendChild(el);
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
});

describe('c-pulse-badge', () => {
    it('renders label text', () => {
        const el = createComponent({ label: 'Draft' });
        const span = el.shadowRoot.querySelector('span');
        expect(span.textContent).toBe('Draft');
    });

    it('applies gray variant class by default', () => {
        const el = createComponent();
        const span = el.shadowRoot.querySelector('span');
        expect(span.className).toContain('pulse-badge-gray');
    });

    it('applies purple variant class', () => {
        const el = createComponent({ variant: 'purple' });
        const span = el.shadowRoot.querySelector('span');
        expect(span.className).toContain('pulse-badge-purple');
    });

    it('applies success variant class', () => {
        const el = createComponent({ variant: 'success' });
        const span = el.shadowRoot.querySelector('span');
        expect(span.className).toContain('pulse-badge-success');
    });

    it('applies error variant class', () => {
        const el = createComponent({ variant: 'error' });
        const span = el.shadowRoot.querySelector('span');
        expect(span.className).toContain('pulse-badge-error');
    });

    it('has role="status" for accessibility', () => {
        const el = createComponent();
        const span = el.shadowRoot.querySelector('span');
        expect(span.getAttribute('role')).toBe('status');
    });
});
