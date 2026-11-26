import { HttpClient, HttpHeaders } from '@angular/common/http';
import { Injectable, inject, signal } from '@angular/core';
import { HubConnection, HubConnectionBuilder, HubConnectionState } from '@microsoft/signalr';
import { firstValueFrom } from 'rxjs';
import { RoundReport, Status, SuiteInfo } from './models';

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
      if (round) this.round.set(round);
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
      this.round.set(r);
      this.error.set(null);
    } catch (e: any) {
      this.error.set(e?.status === 409 ? 'Un giro e gia in corso: aspetta che finisca.' : `Il giro non e partito: ${e?.message ?? e}`);
    }
    await this.refreshStatus();
  }

  async connect(): Promise<void> {
    this.hub = new HubConnectionBuilder().withUrl('/hub').withAutomaticReconnect().build();
    this.hub.on('round', (r: RoundReport) => {
      this.round.set(r);
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
