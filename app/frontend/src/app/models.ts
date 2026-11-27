/** Le forme che restituisce l'API (DevOpsAgents.Api): stessi nomi, in camelCase. */

export interface BlockReason {
  type: string;
  role?: string;
  detail?: string;
  cards?: number[];
}

export interface CardReport {
  id: number;
  title: string;
  state: string;
  stateKey?: string;
  area?: string;
  assignedTo?: string;
  url?: string;
  actions: string[];
  reason?: BlockReason;
  runningRole?: string;
  error?: string;
  featureId?: number;
  /** D57: per una card in on-hold, i passi in ordine per sbloccarla. */
  whatToDo?: string[];
}

/** D51: un problema aperto del supervisore: la cosa, il gesto esatto, il link. */
export interface SupervisorProblem {
  key: string;
  text: string;
  action: string;
  link?: string;
  urgent: boolean;
  lines?: string[];
  since: string;
}

/** D60: una Feature aperta, in ordine di priorita (l'ordine del backlog). */
export interface FeatureReport {
  id: number;
  title: string;
  state: string;
  rank?: number;
  paused: boolean;
  area?: string;
}

export interface QuotaInfo {
  pauseUntil?: string;
  weeklyUtilization?: number;
  weeklyResetsAt?: string;
  fiveHourUtilization?: number;
  fiveHourResetsAt?: string;
}

export interface RoundReport {
  started: string;
  finished: string;
  whatIf: boolean;
  cards: CardReport[];
  log: string[];
  systemPaused?: boolean;
  features?: FeatureReport[];
  quota?: QuotaInfo;
}

export interface Status {
  systemPaused: boolean;
  mode: 'demo' | 'live';
  allowWrites: boolean;
  autoRun: boolean;
  running: boolean;
  nextRun?: string;
  lastRound?: string;
  intervalMinutes: number;
  boardProject: string;
  organization?: string;
}

export interface StateColumn {
  key: string;
  name: string;
}

export interface AreaInfo {
  area: string;
  repo: string;
  component: string;
  source: 'AzureRepos' | 'GitHub';
  gitHubRepo?: string;
  deployPipeline?: number;
  testUrl?: string;
}

export interface SuiteInfo {
  states: StateColumn[];
  areas: AreaInfo[];
  roles: { name: string; model: string; effort: string; advisor?: string }[];
}

/** Il testo del motivo per chi legge la dashboard: lo stesso vocabolario della vista PowerShell. */
export function describeReason(r: BlockReason): string {
  const cards = r.cards?.length ? ` (#${r.cards.join(', #')})` : '';
  switch (r.type) {
    case 'onHold': return `on-hold${r.detail ? `, riparte da: ${r.detail}` : ''}`;
    case 'predecessori': return `aspetta le card precedenti${cards}`;
    case 'limiteRepo': return `repo ${r.detail ?? ''} occupato${cards}`;
    case 'limiteTest': return `Test di ${r.detail ?? ''} occupato${cards}`;
    case 'limiteAmbienti': return `ambienti di collaudo tutti occupati (${r.detail ?? ''})${cards}`;
    case 'limiteSessioni': return `limite di sessioni ${r.detail ?? ''}`;
    case 'quota': return `quota: ${r.detail ?? ''}`;
    case 'areaNonMappata': return `area non in config/mappa.json: ${r.detail ?? ''}`;
    case 'pausa': return r.detail ? `in pausa con la Feature ${r.detail}` : 'in pausa (tag sulla card)';
    case 'senzaFeature': return 'non e figlia di una Feature: collegala a una Feature dalla board';
    case 'pausaSistema': return 'sistema in pausa';
    case 'funzionalitaIllegibile': return `la funzionalita non si legge: ${r.detail ?? ''}`;
    case 'funzionalitaPerduta': return `era sul ramo della funzionalita (${r.detail ?? ''}) che non c'e piu: decidi tu dove portarla`;
    case 'senzaSorelle': return 'card di chiusura senza card sorelle nella Feature';
    case 'attesaCollaudoFunzionalita': return `aspetta il collaudo della funzionalita (card di chiusura in ${r.detail ?? ''})`;
    case 'chiusuraInBozza': return r.detail ?? 'la card di chiusura e in Draft';
    case 'inFeatureSenzaPrUnita': return 'In feature branch ma la PR non risulta completata';
    case 'conflittiFunzionalita': return `la PR della funzionalita ${r.detail ?? ''} e in conflitto con develop`;
    case 'ciRossaFunzionalita': return 'la CI della funzionalita e rossa con errori di codice';
    default: return r.type;
  }
}

/** D51: un run di pipeline (supervisore, sezione Pipeline). */
export interface RunInfo {
  id: number; project: string; pipeline: string; branch: string; author?: string; status: 'inCoda' | 'inCorso' | 'inAttesa' | 'concluso';
  stage?: string; start?: string; end?: string; result?: string; definitionId: number; kind: string; url?: string; orchestrator: boolean;
  components?: string[]; waiting?: string; agent?: string; pool?: string;
}
export interface AgentPoolInfo { pool: string; agents: { name: string; online: boolean; enabled: boolean; jobPipeline?: string; jobUrl?: string }[]; }
export interface PipelineView {
  read: boolean; error?: string; active: RunInfo[]; orchestrators: RunInfo[]; failed: RunInfo[]; errors: string[];
  pools: AgentPoolInfo[]; agentsRead: boolean; agentErrors: string[]; reasons: Record<string, string>;
}

/** D46: il riassunto dell'apprendimento. */
export interface LearningSummary {
  window: string; lessons: number;
  rows: { week: string; monday: string; role: string; blocks: number; onHold: number; corrections: number; lessonsApplied: number }[];
  avoided: { role: string; lesson: string; cards: number[] }[];
}

/** D53: lo stato dell'aggiornamento della suite (aggiornamento.json, con le chiavi della versione PowerShell). */
export interface UpdateStatus {
  spento?: boolean; canale?: string; automatico?: boolean; riavvioNecessario?: boolean;
  installata?: { canale: string; hash: string; data?: string }; disponibile?: { canale: string; hash: string; data?: string } | null;
  ultimoControllo?: string; erroreControllo?: string | null;
  ultimoEsito?: { esito: string; quando?: string; errore?: string; file?: string[]; elenco?: { nome: string; richiesta: string; trovata?: string }[]; sessioni?: number };
  prInArrivo?: { numero: number; titolo: string; url?: string }[];
}

/** La frase dell'esito dell'aggiornamento, come il riquadro Suite della vista. */
export function describeUpdate(u: UpdateStatus): string {
  const e = u.ultimoEsito;
  if (!e) return 'nessun controllo ancora fatto dal supervisore';
  switch (e.esito) {
    case 'aggiornato': return u.disponibile ? 'aggiornato, ma c\'e gia una versione piu nuova' : 'aggiornata all\'ultima versione';
    case 'daAggiornare': return 'c\'e una versione nuova: l\'aggiornamento automatico e spento, aggiorna a mano';
    case 'inAttesaSessioni': return `versione nuova in attesa: ${e.sessioni ?? 0} sessioni di agenti in corso`;
    case 'modificheLocali': return `la copia ha modifiche locali che non so spostare: ${(e.file ?? []).join(', ')}`;
    case 'requisitiMancanti': return `requisiti mancanti: ${(e.elenco ?? []).map(r => `${r.nome} ${r.richiesta} (c'e ${r.trovata ?? 'niente'})`).join(', ')}`;
    case 'fallitoTornatoIndietro': return `aggiornamento fallito, tornata alla versione di prima: ${e.errore ?? ''}`;
    case 'copiaAvanti': return 'la copia ha commit che origine non ha: niente da prendere';
    case 'divergente': return 'la copia e divergente da origine: va sistemata a mano';
    case 'ramoCanaleDivergente': return 'il ramo locale del canale ha commit che origine non ha: va sistemato a mano';
    case 'errore': return `errore: ${e.errore ?? ''}`;
    default: return e.esito;
  }
}
