import { LightningElement, api } from 'lwc';
import { loadPulseBrandTokens } from 'c/pulseBrandTokens';

export default class PulseStateGraph extends LightningElement {
    @api states = [];
    @api selectedStateKey;

    connectedCallback() {
        loadPulseBrandTokens(this);
    }

    get hasStates() {
        return this.states && this.states.length > 0;
    }

    get isEmpty() {
        return !this.hasStates;
    }

    get stateNodes() {
        return (this.states || []).map((s) => ({
            key: s.key,
            label: s.label,
            type: s.type || 'form',
            fieldCount: (s.fields || []).length,
            transitionCount: (s.transitions || []).length,
            selected: s.key === this.selectedStateKey
        }));
    }

    renderedCallback() {
        if (this.hasStates) {
            this._drawArrows();
        }
    }

    handleSelectState(event) {
        this.dispatchEvent(
            new CustomEvent('selectstate', {
                detail: event.detail,
                bubbles: true,
                composed: true
            })
        );
    }

    handleDeleteState(event) {
        this.dispatchEvent(
            new CustomEvent('deletestate', {
                detail: event.detail,
                bubbles: true,
                composed: true
            })
        );
    }

    _drawArrows() {
        const svg = this.template.querySelector('.graph-svg');
        if (!svg) return;

        const container = this.template.querySelector('.graph-nodes');
        if (!container) return;

        const containerRect = container.getBoundingClientRect();

        // Build a map of state key → center position
        const nodeEls = this.template.querySelectorAll('.graph-node-wrapper');
        const positions = new Map();
        nodeEls.forEach((el) => {
            const rect = el.getBoundingClientRect();
            positions.set(el.dataset.key, {
                cx: rect.left - containerRect.left + rect.width / 2,
                bottom: rect.top - containerRect.top + rect.height,
                top: rect.top - containerRect.top
            });
        });

        // Size the SVG to cover the container
        svg.setAttribute('width', containerRect.width);
        svg.setAttribute('height', containerRect.height);

        // Clear previous arrows
        while (svg.firstChild) {
            svg.removeChild(svg.firstChild);
        }

        // Add arrowhead marker def
        const NS = 'http://www.w3.org/2000/svg';
        const defs = document.createElementNS(NS, 'defs');
        const marker = document.createElementNS(NS, 'marker');
        marker.setAttribute('id', 'arrowhead');
        marker.setAttribute('markerWidth', '8');
        marker.setAttribute('markerHeight', '6');
        marker.setAttribute('refX', '8');
        marker.setAttribute('refY', '3');
        marker.setAttribute('orient', 'auto');
        const polygon = document.createElementNS(NS, 'polygon');
        polygon.setAttribute('points', '0 0, 8 3, 0 6');
        polygon.setAttribute('fill', 'var(--pulse-purple, #7B2FF2)');
        marker.appendChild(polygon);
        defs.appendChild(marker);
        svg.appendChild(defs);

        // Draw arrows for each transition
        (this.states || []).forEach((state) => {
            const from = positions.get(state.key);
            if (!from) return;
            (state.transitions || []).forEach((t) => {
                const to = positions.get(t.to);
                if (!to) return;
                const line = document.createElementNS(NS, 'line');
                line.setAttribute('x1', from.cx);
                line.setAttribute('y1', from.bottom + 2);
                line.setAttribute('x2', to.cx);
                line.setAttribute('y2', to.top - 2);
                line.setAttribute('stroke', 'var(--pulse-purple-light, #C4B5FD)');
                line.setAttribute('stroke-width', '2');
                line.setAttribute('marker-end', 'url(#arrowhead)');
                svg.appendChild(line);

                // Signal label at midpoint
                const text = document.createElementNS(NS, 'text');
                text.setAttribute(
                    'x',
                    (from.cx + to.cx) / 2 + 8
                );
                text.setAttribute(
                    'y',
                    (from.bottom + to.top) / 2
                );
                text.setAttribute('fill', 'var(--pulse-slate, #64748B)');
                text.setAttribute('font-size', '11');
                text.setAttribute(
                    'font-family',
                    'var(--pulse-font-mono, monospace)'
                );
                text.textContent = t.signal;
                svg.appendChild(text);
            });
        });
    }
}
