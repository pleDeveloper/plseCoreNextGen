import { createElement } from 'lwc';
import PulseAdminStudio from 'c/pulseAdminStudio';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);


function createComponent() {
    const el = createElement('c-pulse-admin-studio', { is: PulseAdminStudio });
    document.body.appendChild(el);
    return el;
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
});

describe('c-pulse-admin-studio', () => {
    it('renders the shell with topbar and sidebar', () => {
        const el = createComponent();
        const topbar = el.shadowRoot.querySelector('.studio-topbar');
        const sidebar = el.shadowRoot.querySelector('.studio-sidebar');
        expect(topbar).not.toBeNull();
        expect(sidebar).not.toBeNull();
    });

    it('renders the Pulse gradient wordmark', () => {
        const el = createComponent();
        const wordmark = el.shadowRoot.querySelector('.studio-wordmark');
        expect(wordmark).not.toBeNull();
        expect(wordmark.textContent).toBe('Pulse');
        expect(wordmark.className).toContain('pulse-gradient-text');
    });

    it('renders the Admin Studio subtitle', () => {
        const el = createComponent();
        const sub = el.shadowRoot.querySelector('.studio-wordmark-sub');
        expect(sub.textContent).toBe('Admin Studio');
    });

    it('displays environment badge', () => {
        const el = createComponent();
        const badge = el.shadowRoot.querySelector('.studio-env-badge');
        expect(badge).not.toBeNull();
        expect(badge.textContent).toBe('Dev');
    });

    it('renders all five navigation items', () => {
        const el = createComponent();
        const items = el.shadowRoot.querySelectorAll('.studio-nav-item');
        expect(items.length).toBe(5);
    });

    it('defaults to Workflow builder as active nav', () => {
        const el = createComponent();
        const active = el.shadowRoot.querySelector('.studio-nav-item-active');
        expect(active).not.toBeNull();
        expect(active.querySelector('.studio-nav-label').textContent).toBe('Workflow builder');
    });

    it('renders main panel with active heading', () => {
        const el = createComponent();
        const heading = el.shadowRoot.querySelector('.studio-placeholder-heading');
        expect(heading.textContent).toBe('Workflow builder');
    });

    it('switches active panel when nav item clicked', () => {
        const el = createComponent();
        const navItems = el.shadowRoot.querySelectorAll('.studio-nav-item');
        // Click "AI config" (index 2)
        navItems[2].click();
        return Promise.resolve().then(() => {
            const heading = el.shadowRoot.querySelector('.studio-placeholder-heading');
            expect(heading.textContent).toBe('AI config');
            const active = el.shadowRoot.querySelector('.studio-nav-item-active');
            expect(active.querySelector('.studio-nav-label').textContent).toBe('AI config');
        });
    });

    it('switches to each nav item correctly', () => {
        const el = createComponent();
        const expected = [
            'Workflow builder',
            'Integrations hub',
            'AI config',
            'Library',
            'Settings',
        ];
        const navItems = el.shadowRoot.querySelectorAll('.studio-nav-item');

        let chain = Promise.resolve();
        expected.forEach((label, idx) => {
            chain = chain.then(() => {
                navItems[idx].click();
                return Promise.resolve().then(() => {
                    const heading = el.shadowRoot.querySelector('.studio-placeholder-heading');
                    expect(heading.textContent).toBe(label);
                });
            });
        });
        return chain;
    });

    it('has accessible navigation landmark', () => {
        const el = createComponent();
        const nav = el.shadowRoot.querySelector('nav');
        expect(nav.getAttribute('aria-label')).toBe('Admin Studio navigation');
    });

    it('renders the coming soon badge', () => {
        const el = createComponent();
        const badge = el.shadowRoot.querySelector('.pulse-badge');
        expect(badge).not.toBeNull();
        expect(badge.textContent).toContain('Coming in wave 3b');
    });
});
