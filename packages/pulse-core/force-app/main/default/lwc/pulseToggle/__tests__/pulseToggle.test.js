import { createElement } from 'lwc';
import PulseToggle from 'c/pulseToggle';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

function createComponent(props = {}) {
    const el = createElement('c-pulse-toggle', { is: PulseToggle });
    Object.assign(el, { label: 'Auto-assign', ...props });
    document.body.appendChild(el);
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
});

describe('c-pulse-toggle', () => {
    it('renders label', () => {
        const el = createComponent({ label: 'Enable AI' });
        const label = el.shadowRoot.querySelector('label');
        expect(label.textContent).toContain('Enable AI');
    });

    it('renders with role="switch"', () => {
        const el = createComponent();
        const sw = el.shadowRoot.querySelector('[role="switch"]');
        expect(sw).not.toBeNull();
    });

    it('sets aria-checked to false by default', () => {
        const el = createComponent();
        const sw = el.shadowRoot.querySelector('[role="switch"]');
        expect(sw.getAttribute('aria-checked')).toBe('false');
    });

    it('sets aria-checked to true when checked', () => {
        const el = createComponent({ checked: true });
        const sw = el.shadowRoot.querySelector('[role="switch"]');
        expect(sw.getAttribute('aria-checked')).toBe('true');
    });

    it('applies on class when checked', () => {
        const el = createComponent({ checked: true });
        const track = el.shadowRoot.querySelector('.pulse-toggle-track');
        expect(track.className).toContain('pulse-toggle-track-on');
    });

    it('fires change event with toggled value on click', () => {
        const el = createComponent({ checked: false });
        const handler = jest.fn();
        el.addEventListener('change', handler);
        el.shadowRoot.querySelector('.pulse-toggle-track').click();
        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.checked).toBe(true);
    });

    it('fires change event on Space key', () => {
        const el = createComponent({ checked: true });
        const handler = jest.fn();
        el.addEventListener('change', handler);
        const track = el.shadowRoot.querySelector('.pulse-toggle-track');
        track.dispatchEvent(new KeyboardEvent('keydown', { key: ' ' }));
        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.checked).toBe(false);
    });

    it('fires change event on Enter key', () => {
        const el = createComponent({ checked: false });
        const handler = jest.fn();
        el.addEventListener('change', handler);
        const track = el.shadowRoot.querySelector('.pulse-toggle-track');
        track.dispatchEvent(new KeyboardEvent('keydown', { key: 'Enter' }));
        expect(handler).toHaveBeenCalledTimes(1);
    });

    it('does not fire when disabled', () => {
        const el = createComponent({ disabled: true });
        const handler = jest.fn();
        el.addEventListener('change', handler);
        el.shadowRoot.querySelector('.pulse-toggle-track').click();
        expect(handler).not.toHaveBeenCalled();
    });

    it('shows help text when provided', () => {
        const el = createComponent({ helpText: 'Assigns tasks automatically' });
        return Promise.resolve().then(() => {
            const help = el.shadowRoot.querySelector('.pulse-toggle-help');
            expect(help.textContent).toBe('Assigns tasks automatically');
        });
    });

    it('has tabindex for keyboard access', () => {
        const el = createComponent();
        const sw = el.shadowRoot.querySelector('[role="switch"]');
        expect(sw.getAttribute('tabindex')).toBe('0');
    });
});
