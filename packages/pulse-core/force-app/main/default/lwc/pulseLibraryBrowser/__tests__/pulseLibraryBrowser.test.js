import { createElement } from 'lwc';
import { registerApexTestWireAdapter } from '@salesforce/sfdx-lwc-jest';
import PulseLibraryBrowser from 'c/pulseLibraryBrowser';
import listInstalledBundles from '@salesforce/apex/PulseLibraryInstaller.listInstalledBundles';
import installBundle from '@salesforce/apex/PulseLibraryInstaller.installBundle';
import rollbackApex from '@salesforce/apex/PulseLibraryInstaller.rollback';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseLibraryInstaller.listInstalledBundles',
    () => ({ default: jest.fn() }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseLibraryInstaller.installBundle',
    () => ({ default: jest.fn(() => Promise.resolve({ success: true })) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex/PulseLibraryInstaller.rollback',
    () => ({ default: jest.fn(() => Promise.resolve({ success: true })) }),
    { virtual: true }
);

jest.mock(
    '@salesforce/apex',
    () => ({ refreshApex: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

const listAdapter = registerApexTestWireAdapter(listInstalledBundles);

const MOCK_BUNDLES = [
    {
        bundleId: 'a00xx0001',
        bundleKey: 'intake-v1',
        displayName: 'Intake Workflow',
        version: '1.0.0',
        publisherId: 'acme_pub',
        status: 'Installed',
        installedDate: '2026-04-20T12:00:00.000Z',
        installedByName: 'Test User',
        workflowDefinitionId: 'a01xx0001',
        previousBundleId: null,
    },
];

const MOCK_BUNDLE_WITH_PREVIOUS = [
    {
        ...MOCK_BUNDLES[0],
        previousBundleId: 'a00xx0000',
    },
];

function createComponent() {
    const el = createElement('c-pulse-library-browser', {
        is: PulseLibraryBrowser,
    });
    document.body.appendChild(el);
    return el;
}

function flushPromises() {
    return new Promise((resolve) => setTimeout(resolve, 0));
}

afterEach(() => {
    while (document.body.firstChild) {
        document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
});

describe('c-pulse-library-browser', () => {
    it('renders empty state when no bundles', async () => {
        const el = createComponent();
        listAdapter.emit([]);
        await flushPromises();

        const emptyText = el.shadowRoot.querySelector('.library-empty-text');
        expect(emptyText).not.toBeNull();
        expect(emptyText.textContent).toContain(
            'No library bundles installed yet'
        );
    });

    it('renders one bundle with Installed status', async () => {
        const el = createComponent();
        listAdapter.emit(MOCK_BUNDLES);
        await flushPromises();

        const displayName = el.shadowRoot.querySelector(
            '.bundle-display-name'
        );
        expect(displayName).not.toBeNull();
        expect(displayName.textContent).toBe('Intake Workflow');

        const key = el.shadowRoot.querySelector('.bundle-key');
        expect(key.textContent).toBe('intake-v1');
    });

    it('hides rollback button when previousBundleId is null', async () => {
        const el = createComponent();
        listAdapter.emit(MOCK_BUNDLES);
        await flushPromises();

        const rollbackBtn = el.shadowRoot.querySelector(
            'c-pulse-button[data-id]'
        );
        expect(rollbackBtn).toBeNull();
    });

    it('shows rollback button when previousBundleId is present', async () => {
        const el = createComponent();
        listAdapter.emit(MOCK_BUNDLE_WITH_PREVIOUS);
        await flushPromises();

        const rollbackBtn = el.shadowRoot.querySelector(
            'c-pulse-button[data-id]'
        );
        expect(rollbackBtn).not.toBeNull();
    });

    it('rollback click opens confirm modal then calls rollback', async () => {
        rollbackApex.mockResolvedValue({ success: true });
        const el = createComponent();
        listAdapter.emit(MOCK_BUNDLE_WITH_PREVIOUS);
        await flushPromises();

        // Click rollback button
        const rollbackBtn = el.shadowRoot.querySelector(
            'c-pulse-button[data-id]'
        );
        rollbackBtn.click();
        await flushPromises();

        // Confirm modal should be open
        const modals = el.shadowRoot.querySelectorAll('c-pulse-modal');
        const rollbackModal = Array.from(modals).find(
            (m) => m.title === 'Confirm rollback'
        );
        expect(rollbackModal).not.toBeNull();
        expect(rollbackModal.open).toBe(true);

        // Click confirm button
        const confirmBtns = rollbackModal.querySelectorAll('c-pulse-button');
        const confirmBtn = Array.from(confirmBtns).find(
            (b) => b.label === 'Roll back'
        );
        expect(confirmBtn).not.toBeNull();
        confirmBtn.click();
        await flushPromises();

        expect(rollbackApex).toHaveBeenCalledWith({
            bundleRecordId: 'a00xx0001',
        });
    });

    it('install flow opens modal and calls installBundle', async () => {
        installBundle.mockResolvedValue({
            success: true,
            bundleRecordId: 'a00new',
            workflowDefinitionId: 'a01new',
        });
        const el = createComponent();
        listAdapter.emit([]);
        await flushPromises();

        // Open install modal
        const pasteBtn = el.shadowRoot.querySelector('c-pulse-button');
        pasteBtn.click();
        await flushPromises();

        const installModal = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-modal')
        ).find((m) => m.title === 'Install bundle');
        expect(installModal).not.toBeNull();
        expect(installModal.open).toBe(true);

        // Simulate input changes
        const inputs = installModal.querySelectorAll('c-pulse-input');
        const jsonInput = Array.from(inputs).find(
            (i) => i.label === 'Bundle JSON'
        );
        const sigInput = Array.from(inputs).find(
            (i) => i.label === 'Signature'
        );

        jsonInput.dispatchEvent(
            new CustomEvent('change', { detail: { value: '{"test":true}' } })
        );
        sigInput.dispatchEvent(
            new CustomEvent('change', { detail: { value: 'abc123==' } })
        );
        await flushPromises();

        // Click install
        const installBtn = Array.from(
            installModal.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === 'Install');
        installBtn.click();
        await flushPromises();

        expect(installBundle).toHaveBeenCalledWith({
            bundleJson: '{"test":true}',
            signatureB64: 'abc123==',
        });
    });
});
