import { createElement } from 'lwc';
import PulseAdminStudio from 'c/pulseAdminStudio';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    'c/pulseStore',
    () => ({
        getState: jest.fn(() => ({
            workflow: { schema: 'pulse.workflow.v1', workflowKey: '', version: 1, subjectKinds: [], states: [] },
            ui: { selectedStateKey: null, selectedFieldKey: null, dirty: false, publishing: false }
        })),
        subscribe: jest.fn(() => () => {}),
        dispatch: jest.fn(),
        resetStore: jest.fn()
    }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseWorkflowBuilderController.saveWorkflow',
    () => ({ default: jest.fn(() => Promise.resolve({ success: true, recordId: '001xx001', errors: [] })) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseWorkflowBuilderController.publishWorkflow',
    () => ({ default: jest.fn(() => Promise.resolve({ status: 'Queued', message: 'ok' })) }),
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

    it('renders all seven navigation items', () => {
        const el = createComponent();
        const items = el.shadowRoot.querySelectorAll('.studio-nav-item');
        expect(items.length).toBe(7);
    });

    it('defaults to Workflow builder as active nav', () => {
        const el = createComponent();
        const active = el.shadowRoot.querySelector('.studio-nav-item-active');
        expect(active).not.toBeNull();
        expect(active.querySelector('.studio-nav-label').textContent).toBe('Workflow builder');
    });

    it('renders the workflow builder component when workflow-builder is active', () => {
        const el = createComponent();
        const builder = el.shadowRoot.querySelector('c-pulse-workflow-builder');
        expect(builder).not.toBeNull();
    });

    it('shows placeholder card when a non-builder tab is active', () => {
        const el = createComponent();
        const navItems = el.shadowRoot.querySelectorAll('.studio-nav-item');
        // Click "AI config" (index 2)
        navItems[2].click();
        return Promise.resolve().then(() => {
            const heading = el.shadowRoot.querySelector('.studio-placeholder-heading');
            expect(heading.textContent).toBe('AI config');
            // Builder should not be rendered
            const builder = el.shadowRoot.querySelector('c-pulse-workflow-builder');
            expect(builder).toBeNull();
        });
    });

    it('switches active panel when nav item clicked', () => {
        const el = createComponent();
        const navItems = el.shadowRoot.querySelectorAll('.studio-nav-item');
        navItems[2].click();
        return Promise.resolve().then(() => {
            const heading = el.shadowRoot.querySelector('.studio-placeholder-heading');
            expect(heading.textContent).toBe('AI config');
            const active = el.shadowRoot.querySelector('.studio-nav-item-active');
            expect(active.querySelector('.studio-nav-label').textContent).toBe('AI config');
        });
    });

    it('shows placeholder for non-builder tabs with coming badge', () => {
        const el = createComponent();
        const navItems = el.shadowRoot.querySelectorAll('.studio-nav-item');
        navItems[5].click(); // Library
        return Promise.resolve().then(() => {
            const badge = el.shadowRoot.querySelector('.pulse-badge');
            expect(badge).not.toBeNull();
            expect(badge.textContent).toContain('Coming in wave 3c+');
        });
    });

    it('renders conversation hub when Conversations nav clicked', () => {
        const el = createComponent();
        const navItems = el.shadowRoot.querySelectorAll('.studio-nav-item');
        // Conversations is at index 4 (after action-hub)
        navItems[4].click();
        return Promise.resolve().then(() => {
            const hub = el.shadowRoot.querySelector('c-pulse-conversation-hub');
            expect(hub).not.toBeNull();
            // Builder should not be rendered
            const builder = el.shadowRoot.querySelector('c-pulse-workflow-builder');
            expect(builder).toBeNull();
            // Placeholder should not be rendered
            const placeholder = el.shadowRoot.querySelector('.studio-placeholder-heading');
            expect(placeholder).toBeNull();
        });
    });

    it('has accessible navigation landmark', () => {
        const el = createComponent();
        const nav = el.shadowRoot.querySelector('nav');
        expect(nav.getAttribute('aria-label')).toBe('Admin Studio navigation');
    });
});
