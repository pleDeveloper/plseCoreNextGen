import { createElement } from 'lwc';
import PulseModal from 'c/pulseModal';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

function createComponent(props = {}) {
    const el = createElement('c-pulse-modal', { is: PulseModal });
    Object.assign(el, props);
    document.body.appendChild(el);
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
});

describe('c-pulse-modal', () => {
    it('does not render when open is false', () => {
        const el = createComponent({ open: false });
        const backdrop = el.shadowRoot.querySelector('.pulse-modal-backdrop');
        expect(backdrop).toBeNull();
    });

    it('renders backdrop and dialog when open', () => {
        const el = createComponent({ open: true, title: 'Confirm' });
        return Promise.resolve().then(() => {
            const backdrop = el.shadowRoot.querySelector('.pulse-modal-backdrop');
            const dialog = el.shadowRoot.querySelector('[role="dialog"]');
            expect(backdrop).not.toBeNull();
            expect(dialog).not.toBeNull();
        });
    });

    it('renders title in header', () => {
        const el = createComponent({ open: true, title: 'Publish workflow' });
        return Promise.resolve().then(() => {
            const h2 = el.shadowRoot.querySelector('.pulse-modal-title');
            expect(h2.textContent).toBe('Publish workflow');
        });
    });

    it('sets aria-modal and aria-label', () => {
        const el = createComponent({ open: true, title: 'Settings' });
        return Promise.resolve().then(() => {
            const dialog = el.shadowRoot.querySelector('[role="dialog"]');
            expect(dialog.getAttribute('aria-modal')).toBe('true');
            expect(dialog.getAttribute('aria-label')).toBe('Settings');
        });
    });

    it('applies size class', () => {
        const el = createComponent({ open: true, size: 'lg' });
        return Promise.resolve().then(() => {
            const dialog = el.shadowRoot.querySelector('.pulse-modal-dialog');
            expect(dialog.className).toContain('pulse-modal-lg');
        });
    });

    it('renders close button when dismissible', () => {
        const el = createComponent({ open: true, title: 'Test', dismissible: true });
        return Promise.resolve().then(() => {
            const close = el.shadowRoot.querySelector('.pulse-modal-close');
            expect(close).not.toBeNull();
            expect(close.getAttribute('aria-label')).toBe('Close');
        });
    });

    it('fires close event when close button clicked', () => {
        const el = createComponent({ open: true, title: 'Test', dismissible: true });
        const handler = jest.fn();
        el.addEventListener('close', handler);
        return Promise.resolve().then(() => {
            el.shadowRoot.querySelector('.pulse-modal-close').click();
            expect(handler).toHaveBeenCalledTimes(1);
        });
    });

    it('fires close event on backdrop click when dismissible', () => {
        const el = createComponent({ open: true, title: 'Test', dismissible: true });
        const handler = jest.fn();
        el.addEventListener('close', handler);
        return Promise.resolve().then(() => {
            el.shadowRoot.querySelector('.pulse-modal-backdrop').click();
            expect(handler).toHaveBeenCalledTimes(1);
        });
    });

    it('does not fire close on backdrop click when not dismissible', () => {
        const el = createComponent({ open: true, title: 'Test', dismissible: false });
        const handler = jest.fn();
        el.addEventListener('close', handler);
        return Promise.resolve().then(() => {
            el.shadowRoot.querySelector('.pulse-modal-backdrop').click();
            expect(handler).not.toHaveBeenCalled();
        });
    });

    it('fires close event on Escape key when dismissible', () => {
        const el = createComponent({ open: true, title: 'Test', dismissible: true });
        const handler = jest.fn();
        el.addEventListener('close', handler);
        return Promise.resolve().then(() => {
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
            expect(handler).toHaveBeenCalledTimes(1);
        });
    });

    it('does not fire close on Escape when not dismissible', () => {
        const el = createComponent({ open: true, title: 'Test', dismissible: false });
        const handler = jest.fn();
        el.addEventListener('close', handler);
        return Promise.resolve().then(() => {
            document.dispatchEvent(new KeyboardEvent('keydown', { key: 'Escape' }));
            expect(handler).not.toHaveBeenCalled();
        });
    });

    it('renders default md size class', () => {
        const el = createComponent({ open: true });
        return Promise.resolve().then(() => {
            const dialog = el.shadowRoot.querySelector('.pulse-modal-dialog');
            expect(dialog.className).toContain('pulse-modal-md');
        });
    });
});
