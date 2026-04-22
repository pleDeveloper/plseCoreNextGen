import { createElement } from 'lwc';
import PulseConditionBuilder from 'c/pulseConditionBuilder';

jest.mock(
    '@salesforce/apex/PulseWorkflowTriggerController.describeObjectFields',
    () => ({
        default: jest.fn(() =>
            Promise.resolve([
                { apiName: 'Industry', label: 'Industry', fieldType: 'STRING' },
                { apiName: 'StageName', label: 'Stage', fieldType: 'PICKLIST',
                  picklistValues: ['Prospecting', 'Closed Won'] }
            ])
        )
    }),
    { virtual: true }
);

function createComponent(props = {}) {
    const el = createElement('c-pulse-condition-builder', {
        is: PulseConditionBuilder
    });
    Object.assign(el, props);
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
});

describe('c-pulse-condition-builder', () => {
    it('renders a single blank rule when no tree is provided', async () => {
        const el = createComponent({ targetObject: 'Account' });
        await flushPromises();
        const rows = el.shadowRoot.querySelectorAll('.cb-rule-row');
        expect(rows.length).toBe(1);
    });

    it('hydrates from an existing tree', async () => {
        const el = createComponent({
            targetObject: 'Account',
            conditionTree: {
                logic: 'AND',
                rules: [
                    { field: 'Industry', op: 'EQUALS', value: 'Biotechnology' },
                    { field: 'Industry', op: 'EQUALS', value: 'Agriculture' }
                ]
            }
        });
        await flushPromises();
        const rows = el.shadowRoot.querySelectorAll('.cb-rule-row');
        expect(rows.length).toBe(2);
        // Logic selector should be visible when >1 rule
        const toggle = el.shadowRoot.querySelector('.cb-logic-toggle');
        expect(toggle).not.toBeNull();
        expect(toggle.textContent.trim()).toBe('ALL of');
    });

    it('toggles logic between AND and OR and emits change', async () => {
        const el = createComponent({
            targetObject: 'Account',
            conditionTree: {
                logic: 'AND',
                rules: [
                    { field: 'Industry', op: 'EQUALS', value: 'A' },
                    { field: 'Industry', op: 'EQUALS', value: 'B' }
                ]
            }
        });
        await flushPromises();

        const handler = jest.fn();
        el.addEventListener('change', handler);

        const toggle = el.shadowRoot.querySelector('.cb-logic-toggle');
        toggle.click();
        await flushPromises();

        expect(handler).toHaveBeenCalled();
        const detail = handler.mock.calls[0][0].detail;
        expect(detail.tree.logic).toBe('OR');
    });

    it('emits change when add rule is clicked', async () => {
        const el = createComponent({ targetObject: 'Account' });
        await flushPromises();

        const handler = jest.fn();
        el.addEventListener('change', handler);

        const addBtn = Array.from(
            el.shadowRoot.querySelectorAll('c-pulse-button')
        ).find((b) => b.label === '+ Add rule');
        expect(addBtn).not.toBeUndefined();
        addBtn.click();
        await flushPromises();

        expect(handler).toHaveBeenCalled();
        const rows = el.shadowRoot.querySelectorAll('.cb-rule-row');
        expect(rows.length).toBe(2);
    });

    it('hides change-aware operators when hideChangeOps=true', async () => {
        const el = createComponent({
            targetObject: 'Account',
            hideChangeOps: true
        });
        await flushPromises();
        const opSelect = el.shadowRoot.querySelector('.cb-rule-op');
        const values = Array.from(opSelect.querySelectorAll('option')).map(
            (o) => o.value
        );
        expect(values).not.toContain('IS_CHANGED');
        expect(values).not.toContain('CHANGED_TO');
        expect(values).not.toContain('CHANGED_FROM');
    });
});
