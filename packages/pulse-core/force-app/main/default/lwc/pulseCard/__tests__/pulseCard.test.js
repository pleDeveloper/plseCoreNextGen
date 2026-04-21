import { createElement } from 'lwc';
import PulseCard from 'c/pulseCard';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

function createComponent(props = {}) {
    const el = createElement('c-pulse-card', { is: PulseCard });
    Object.assign(el, props);
    document.body.appendChild(el);
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
});

describe('c-pulse-card', () => {
    it('renders the card wrapper', () => {
        const el = createComponent();
        const card = el.shadowRoot.querySelector('.pulse-card');
        expect(card).not.toBeNull();
    });

    it('renders heading when provided', () => {
        const el = createComponent({ heading: 'Workflow builder' });
        return Promise.resolve().then(() => {
            const h3 = el.shadowRoot.querySelector('h3');
            expect(h3.textContent).toBe('Workflow builder');
        });
    });

    it('does not render heading when absent', () => {
        const el = createComponent();
        const h3 = el.shadowRoot.querySelector('h3');
        expect(h3).toBeNull();
    });

    it('applies elevated class for hover effect', () => {
        const el = createComponent({ elevated: true });
        const card = el.shadowRoot.querySelector('.pulse-card');
        expect(card.className).toContain('pulse-card-elevated');
    });

    it('does not apply elevated class by default', () => {
        const el = createComponent();
        const card = el.shadowRoot.querySelector('.pulse-card');
        expect(card.className).not.toContain('pulse-card-elevated');
    });

    it('renders slotted content area', () => {
        const el = createComponent();
        const slot = el.shadowRoot.querySelector('slot');
        expect(slot).not.toBeNull();
    });
});
