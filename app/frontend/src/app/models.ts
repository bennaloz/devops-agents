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
