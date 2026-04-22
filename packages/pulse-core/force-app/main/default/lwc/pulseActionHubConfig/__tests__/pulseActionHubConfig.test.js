import { createElement } from 'lwc';
import PulseActionHubConfig from 'c/pulseActionHubConfig';
import listColumnConfigs from '@salesforce/apex/PulseGlobalActionHubController.listColumnConfigs';
import upsertColumnConfig from '@salesforce/apex/PulseGlobalActionHubController.upsertColumnConfig';

jest.mock(
    'c/pulseBrandTokens',
    () => ({ loadPulseBrandTokens: jest.fn(() => Promise.resolve()) }),
    { virtual: true }
);

const MOCK_CONFIGS = [
    {
        configKey: 'Opportunity_Columns',
        targetObject: 'Opportunity',
        columnsJson: '[{"field":"Name","label":"Name"},{"field":"Amount","label":"Amount"}]',
        active: true,
        masterLabel: 'Opportunity Columns',
    },
    {
        configKey: 'Default_Fallback',
        targetObject: '*',
        columnsJson: '[{"field":"Name","label":"Record"}]',
        active: true,
        masterLabel: 'Default Fallback',
    },
];

function createComponent() {
    const el = createElement('c-pulse-action-hub-config', { is: PulseActionHubConfig });
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

describe('c-pulse-action-hub-config', () => {
    it('lists column configs from Apex', async () => {
        listColumnConfigs.mockResolvedValue(MOCK_CONFIGS);
        const el = createComponent();
        await flushPromises();

        const rows = el.shadowRoot.querySelectorAll('.cfg-list-row');
        expect(rows.length).toBe(2);

        const titles = el.shadowRoot.querySelectorAll('.cfg-list-title');
        expect(titles[0].textContent).toBe('Opportunity Columns');
        expect(titles[1].textContent).toBe('Default Fallback');
    });

    it('populates editor when a row is clicked', async () => {
        listColumnConfigs.mockResolvedValue(MOCK_CONFIGS);
        const el = createComponent();
        await flushPromises();

        const firstRow = el.shadowRoot.querySelector('.cfg-list-row');
        firstRow.click();
        await flushPromises();

        const title = el.shadowRoot.querySelector('.cfg-editor-title');
        expect(title.textContent).toContain('Opportunity_Columns');
    });

    it('saves a new config by calling upsertColumnConfig', async () => {
        listColumnConfigs.mockResolvedValue(MOCK_CONFIGS);
        const el = createComponent();
        await flushPromises();

        // Queue the upsert response
        upsertColumnConfig.mockResolvedValueOnce({
            success: true,
            deploymentJobId: '0Af000000000001',
            message: 'Deployment enqueued',
        });

        const inputs = el.shadowRoot.querySelectorAll('c-pulse-input');
        inputs[0].dispatchEvent(new CustomEvent('change', { detail: { value: 'Account_Cols' } }));
        inputs[1].dispatchEvent(new CustomEvent('change', { detail: { value: 'Account' } }));
        inputs[2].dispatchEvent(new CustomEvent('change', { detail: { value: 'Account Cols' } }));
        await flushPromises();

        const saveBtn = el.shadowRoot.querySelector('.cfg-save-row c-pulse-button');
        saveBtn.click();
        await flushPromises();

        expect(upsertColumnConfig).toHaveBeenCalledWith(
            expect.objectContaining({
                payload: expect.objectContaining({
                    configKey: 'Account_Cols',
                    targetObject: 'Account',
                }),
            })
        );
    });
});
