import { createElement } from 'lwc';
import PulseInput from 'c/pulseInput';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

function createComponent(props = {}) {
    const el = createElement('c-pulse-input', { is: PulseInput });
    Object.assign(el, { label: 'Email', ...props });
    document.body.appendChild(el);
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
});

describe('c-pulse-input', () => {
    it('renders label and input', () => {
        const el = createComponent({ label: 'Full name' });
        const label = el.shadowRoot.querySelector('label');
        const input = el.shadowRoot.querySelector('input');
        expect(label.textContent).toContain('Full name');
        expect(input).not.toBeNull();
    });

    it('sets input type', () => {
        const el = createComponent({ type: 'email' });
        const input = el.shadowRoot.querySelector('input');
        expect(input.type).toBe('email');
    });

    it('sets placeholder', () => {
        const el = createComponent({ placeholder: 'Enter email' });
        const input = el.shadowRoot.querySelector('input');
        expect(input.placeholder).toBe('Enter email');
    });

    it('marks required with aria and abbr', () => {
        const el = createComponent({ required: true });
        const input = el.shadowRoot.querySelector('input');
        const abbr = el.shadowRoot.querySelector('abbr');
        expect(input.required).toBe(true);
        expect(input.getAttribute('aria-required')).toBe('true');
        expect(abbr).not.toBeNull();
    });

    it('shows error text and sets aria-invalid', () => {
        const el = createComponent({ error: 'Invalid format' });
        return Promise.resolve().then(() => {
            const input = el.shadowRoot.querySelector('input');
            const errText = el.shadowRoot.querySelector('.pulse-input-error-text');
            expect(input.getAttribute('aria-invalid')).toBe('true');
            expect(errText.textContent).toBe('Invalid format');
        });
    });

    it('applies error border class', () => {
        const el = createComponent({ error: 'Oops' });
        const input = el.shadowRoot.querySelector('input');
        expect(input.className).toContain('pulse-input-error');
    });

    it('shows help text', () => {
        const el = createComponent({ helpText: 'We will not share this' });
        return Promise.resolve().then(() => {
            const help = el.shadowRoot.querySelector('.pulse-input-help-text');
            expect(help.textContent).toBe('We will not share this');
        });
    });

    it('fires change event on input', () => {
        const el = createComponent();
        const handler = jest.fn();
        el.addEventListener('change', handler);
        const input = el.shadowRoot.querySelector('input');
        input.value = 'test@example.com';
        input.dispatchEvent(new Event('input'));
        expect(handler).toHaveBeenCalledTimes(1);
        expect(handler.mock.calls[0][0].detail.value).toBe('test@example.com');
    });
});
