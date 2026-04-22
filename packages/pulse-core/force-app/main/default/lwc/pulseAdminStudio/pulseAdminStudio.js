import { LightningElement, track } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

const NAV_ITEMS = [
    {
        key: 'workflow-builder',
        label: 'Workflow builder',
        description: 'Design, configure, and publish workflow definitions with a visual canvas.',
        icon: 'M9 5H7a2 2 0 00-2 2v12a2 2 0 002 2h10a2 2 0 002-2V7a2 2 0 00-2-2h-2M9 5a2 2 0 002 2h2a2 2 0 002-2M9 5a2 2 0 012-2h2a2 2 0 012 2m-3 7h3m-3 4h3m-6-4h.01M9 16h.01',
    },
    {
        key: 'integrations-hub',
        label: 'Integrations hub',
        description: 'Manage named credentials, external providers, and channel adapters.',
        icon: 'M13.828 10.172a4 4 0 00-5.656 0l-4 4a4 4 0 105.656 5.656l1.102-1.101m-.758-4.899a4 4 0 005.656 0l4-4a4 4 0 00-5.656-5.656l-1.1 1.1',
    },
    {
        key: 'ai-config',
        label: 'AI config',
        description: 'Configure AI providers, tool registrations, HITL policies, and extraction profiles.',
        icon: 'M9.663 17h4.673M12 3v1m6.364 1.636l-.707.707M21 12h-1M4 12H3m3.343-5.657l-.707-.707m2.828 9.9a5 5 0 117.072 0l-.548.547A3.374 3.374 0 0014 18.469V19a2 2 0 11-4 0v-.531c0-.895-.356-1.754-.988-2.386l-.548-.547z',
    },
    {
        key: 'action-hub',
        label: 'Action hub',
        description: 'Review and resolve pending HITL approvals across workflow instances.',
        icon: 'M9 12l2 2 4-4m6 2a9 9 0 11-18 0 9 9 0 0118 0z',
    },
    {
        key: 'conversations',
        label: 'Conversations',
        description: 'Review AI-extracted facts from conversations and accept or reject them.',
        icon: 'M8 12h.01M12 12h.01M16 12h.01M21 12c0 4.418-4.03 8-9 8a9.863 9.863 0 01-4.255-.949L3 20l1.395-3.72C3.512 15.042 3 13.574 3 12c0-4.418 4.03-8 9-8s9 3.582 9 8z',
    },
    {
        key: 'sla',
        label: 'SLA',
        description: 'Track stage dwell times and predict workflow exit dates.',
        icon: 'M12 8v4l3 3m6-3a9 9 0 11-18 0 9 9 0 0118 0z',
    },
    {
        key: 'library',
        label: 'Library',
        description: 'Browse published workflow definitions, templates, and reusable step patterns.',
        icon: 'M19 11H5m14 0a2 2 0 012 2v6a2 2 0 01-2 2H5a2 2 0 01-2-2v-6a2 2 0 012-2m14 0V9a2 2 0 00-2-2M5 11V9a2 2 0 012-2m0 0V5a2 2 0 012-2h6a2 2 0 012 2v2M7 7h10',
    },
    {
        key: 'settings',
        label: 'Settings',
        description: 'Feature flags, permission sets, deployment preferences, and org-level configuration.',
        icon: 'M10.325 4.317c.426-1.756 2.924-1.756 3.35 0a1.724 1.724 0 002.573 1.066c1.543-.94 3.31.826 2.37 2.37a1.724 1.724 0 001.066 2.573c1.756.426 1.756 2.924 0 3.35a1.724 1.724 0 00-1.066 2.573c.94 1.543-.826 3.31-2.37 2.37a1.724 1.724 0 00-2.573 1.066c-.426 1.756-2.924 1.756-3.35 0a1.724 1.724 0 00-2.573-1.066c-1.543.94-3.31-.826-2.37-2.37a1.724 1.724 0 00-1.066-2.573c-1.756-.426-1.756-2.924 0-3.35a1.724 1.724 0 001.066-2.573c-.94-1.543.826-3.31 2.37-2.37.996.608 2.296.07 2.572-1.065z M15 12a3 3 0 11-6 0 3 3 0 016 0z',
    },
];

export default class PulseAdminStudio extends LightningElement {
    @track activeNav = 'workflow-builder';

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    get navItems() {
        return NAV_ITEMS.map((item) => ({
            ...item,
            itemClass: item.key === this.activeNav
                ? 'studio-nav-item studio-nav-item-active'
                : 'studio-nav-item',
            isActive: item.key === this.activeNav,
        }));
    }

    get activePanel() {
        return NAV_ITEMS.find((n) => n.key === this.activeNav) || NAV_ITEMS[0];
    }

    get panelHeading() {
        return this.activePanel.label;
    }

    get panelDescription() {
        return this.activePanel.description;
    }

    get isWorkflowBuilder() {
        return this.activeNav === 'workflow-builder';
    }

    get isActionHub() {
        return this.activeNav === 'action-hub';
    }

    get isConversations() {
        return this.activeNav === 'conversations';
    }

    get isSla() {
        return this.activeNav === 'sla';
    }

    handleNavClick(event) {
        const key = event.currentTarget.dataset.key;
        if (key) {
            this.activeNav = key;
        }
    }
}
