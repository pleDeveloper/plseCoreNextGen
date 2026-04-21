import { createElement } from 'lwc';
import PulseButton from 'c/pulseButton';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

function createComponent(props = {}) {
    const el = createElement('c-pulse-button', { is: PulseButton });
    Object.assign(el, { label: 'Save', ...props });
    document.body.appendChild(el);
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
});

describe('c-pulse-button', () => {
    it('renders with label', () => {
        const el = createComponent({ label: 'Publish workflow' });
        const btn = el.shadowRoot.querySelector('button');
        expect(btn).not.toBeNull();
        expect(btn.textContent).toContain('Publish workflow');
    });

    it('applies primary variant class by default', () => {
        const el = createComponent();
        const btn = el.shadowRoot.querySelector('button');
        expect(btn.className).toContain('pulse-btn-primary');
    });

    it('applies secondary variant class', () => {
        const el = createComponent({ variant: 'secondary' });
        const btn = el.shadowRoot.querySelector('button');
        expect(btn.className).toContain('pulse-btn-secondary');
    });

    it('applies dark variant class', () => {
        const el = createComponent({ variant: 'dark' });
        const btn = el.shadowRoot.querySelector('button');
        expect(btn.className).toContain('pulse-btn-dark');
    });

    it('applies ghost variant class', () => {
        const el = createComponent({ variant: 'ghost' });
        const btn = el.shadowRoot.querySelector('button');
        expect(btn.className).toContain('pulse-btn-ghost');
    });

    it('applies size class for sm', () => {
        const el = createComponent({ size: 'sm' });
        const btn = el.shadowRoot.querySelector('button');
        expect(btn.className).toContain('pulse-btn-sm');
    });

    it('applies size class for lg', () => {
        const el = createComponent({ size: 'lg' });
        const btn = el.shadowRoot.querySelector('button');
        expect(btn.className).toContain('pulse-btn-lg');
    });

    it('sets disabled attribute', () => {
        const el = createComponent({ disabled: true });
        const btn = el.shadowRoot.querySelector('button');
        expect(btn.disabled).toBe(true);
        expect(btn.getAttribute('aria-disabled')).toBe('true');
    });

    it('fires click event when not disabled', () => {
        const el = createComponent();
        const handler = jest.fn();
        el.addEventListener('click', handler);
        el.shadowRoot.querySelector('button').click();
        expect(handler).toHaveBeenCalledTimes(1);
    });

    it('does not fire click when disabled', () => {
        const el = createComponent({ disabled: true });
        const handler = jest.fn();
        el.addEventListener('click', handler);
        el.shadowRoot.querySelector('button').click();
        expect(handler).not.toHaveBeenCalled();
    });
});
