import { HttpClient, HttpHeaders } from '@angular/common/http';
import { Injectable, inject, signal } from '@angular/core';
import { HubConnection, HubConnectionBuilder, HubConnectionState } from '@microsoft/signalr';
import { firstValueFrom } from 'rxjs';
import { FeatureReport, RoundReport, Status, SuiteInfo } from './models';

/** Le chiamate all'API e gli aggiornamenti live (SignalR): ogni giro finito arriva da solo. */
@Injectable({ providedIn: 'root' })
export class ApiService {
  private readonly http = inject(HttpClient);
  // l'API rifiuta le scritture senza questa intestazione: un link o un form da un altro sito non la puo mettere
  private readonly writeHeaders = new HttpHeaders({ 'X-DevOps-Agents': '1' });
  private hub?: HubConnection;

  readonly status = signal<Status | null>(null);
  readonly suite = signal<SuiteInfo | null>(null);
  readonly round = signal<RoundReport | null>(null);
  readonly features = signal<FeatureReport[]>([]);
  readonly live = signal(false);
  readonly error = signal<string | null>(null);

  async load(): Promise<void> {
    try {
      const [status, suite, round] = await Promise.all([
        firstValueFrom(this.http.get<Status>('/api/status')),
        firstValueFrom(this.http.get<SuiteInfo>('/api/config')),
        firstValueFrom(this.http.get<RoundReport | null>('/api/round')),
      ]);
      this.status.set(status);
      this.suite.set(suite);
      if (round) { this.round.set(round); if (round.features) this.features.set(round.features); }
      this.error.set(null);
    } catch (e) {
      this.error.set(`API non raggiungibile: ${(e as Error).message}`);
    }
  }

  async refreshStatus(): Promise<void> {
    try { this.status.set(await firstValueFrom(this.http.get<Status>('/api/status'))); } catch { /* la prossima volta */ }
  }

  async runRound(whatIf: boolean): Promise<void> {
    try {
      const r = await firstValueFrom(this.http.post<RoundReport>(`/api/round?whatIf=${whatIf}`, null, { headers: this.writeHeaders }));
      this.setRound(r);
      this.error.set(null);
    } catch (e: any) {
      this.error.set(e?.status === 409 ? 'Un giro e gia in corso: aspetta che finisca.' : `Il giro non e partito: ${e?.message ?? e}`);
    }
    await this.refreshStatus();
  }

  private setRound(r: RoundReport): void {
    this.round.set(r);
    if (r.features) this.features.set(r.features);
  }

  /** D60: pausa o ripresa di una Feature, e il riordino (dopo = id della Feature che la precede, 0 = in cima). */
  async setFeaturePaused(id: number, active: boolean): Promise<void> {
    await this.post<FeatureReport[]>(`/api/features/${id}/pause?active=${active}`, f => this.features.set(f));
  }

  async moveFeature(id: number, after: number): Promise<void> {
    await this.post<FeatureReport[]>(`/api/features/${id}/move?after=${after}`, f => this.features.set(f));
  }

  async setSystemPaused(active: boolean): Promise<void> {
    await this.post(`/api/system/pause?active=${active}`, () => {});
    await this.refreshStatus();
  }

  private async post<T>(url: string, done: (r: T) => void): Promise<void> {
    try {
      done(await firstValueFrom(this.http.post<T>(url, null, { headers: this.writeHeaders })));
      this.error.set(null);
    } catch (e: any) {
      this.error.set(e?.error?.error ?? `Il comando non e arrivato: ${e?.message ?? e}`);
    }
  }

  async connect(): Promise<void> {
    this.hub = new HubConnectionBuilder().withUrl('/hub').withAutomaticReconnect().build();
    this.hub.on('round', (r: RoundReport) => {
      this.setRound(r);
      void this.refreshStatus();
    });
    this.hub.onreconnected(() => this.live.set(true));
    this.hub.onreconnecting(() => this.live.set(false));
    this.hub.onclose(() => this.live.set(false));
    try {
      await this.hub.start();
      this.live.set(this.hub.state === HubConnectionState.Connected);
    } catch {
      this.live.set(false);
    }
  }
}
