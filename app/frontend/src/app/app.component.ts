import { DatePipe } from '@angular/common';
import { Component, OnInit, computed, inject, signal } from '@angular/core';
import { ApiService } from './api.service';
import { CardReport, describeReason } from './models';

interface Column {
  key: string;
  name: string;
  cards: CardReport[];
}

@Component({
  selector: 'app-root',
  standalone: true,
  imports: [DatePipe],
  templateUrl: './app.component.html',
  styleUrl: './app.component.css',
})
export class AppComponent implements OnInit {
  readonly api = inject(ApiService);
  readonly busy = signal(false);
  readonly selected = signal<number | null>(null);
  readonly showLog = signal(true);
  readonly describeReason = describeReason;

  /** Una colonna per stato del flusso, nell'ordine del flusso; le card di stati fuori elenco in fondo. */
  readonly columns = computed<Column[]>(() => {
    const states = this.api.suite()?.states ?? [];
    const cards = this.api.round()?.cards ?? [];
    const cols: Column[] = states.map(s => ({ key: s.key, name: s.name, cards: cards.filter(c => c.stateKey === s.key) }));
    const known = new Set(states.map(s => s.key));
    const other = cards.filter(c => !c.stateKey || !known.has(c.stateKey));
    if (other.length) cols.push({ key: 'altro', name: 'Altro', cards: other });
    return cols;
  });

  readonly counts = computed(() => {
    const cards = this.api.round()?.cards ?? [];
    return {
      total: cards.length,
      sessions: cards.filter(c => c.runningRole).length,
      blocked: cards.filter(c => c.reason).length,
      errors: cards.filter(c => c.error).length,
    };
  });

  readonly selectedCard = computed(() => this.api.round()?.cards.find(c => c.id === this.selected()) ?? null);
  readonly selectedLog = computed(() => {
    const id = this.selected();
    const log = this.api.round()?.log ?? [];
    return id === null ? log : log.filter(l => l.startsWith(`card ${id}:`));
  });

  async ngOnInit(): Promise<void> {
    await this.api.load();
    await this.api.connect();
  }

  /** Quante card ha ogni Feature nel giro, per la riga della Feature. */
  readonly cardsPerFeature = computed(() => {
    const m = new Map<number, number>();
    for (const c of this.api.round()?.cards ?? []) if (c.featureId != null) m.set(c.featureId, (m.get(c.featureId) ?? 0) + 1);
    return m;
  });

  async act(work: () => Promise<void>): Promise<void> {
    this.busy.set(true);
    try { await work(); } finally { this.busy.set(false); }
  }

  toggleSystemPause(paused: boolean): Promise<void> {
    return this.act(() => this.api.setSystemPaused(!paused));
  }

  toggleFeaturePause(id: number, paused: boolean): Promise<void> {
    return this.act(() => this.api.setFeaturePaused(id, !paused));
  }

  /** Su di un posto: dopo la Feature che sta due posti sopra (0 = in cima). Giu: dopo quella che sta sotto. */
  moveUp(i: number): Promise<void> {
    const f = this.api.features();
    return this.act(() => this.api.moveFeature(f[i].id, i >= 2 ? f[i - 2].id : 0));
  }

  moveDown(i: number): Promise<void> {
    const f = this.api.features();
    return this.act(() => this.api.moveFeature(f[i].id, f[i + 1].id));
  }

  async run(whatIf: boolean): Promise<void> {
    this.busy.set(true);
    try { await this.api.runRound(whatIf); } finally { this.busy.set(false); }
  }

  toggle(id: number): void {
    this.selected.set(this.selected() === id ? null : id);
  }

  reasonClass(c: CardReport): string {
    if (c.error) return 'errore';
    if (c.reason?.type === 'onHold') return 'attesa';
    return c.reason ? 'fermo' : '';
  }
}
