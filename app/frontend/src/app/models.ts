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
}

export interface RoundReport {
  started: string;
  finished: string;
  whatIf: boolean;
  cards: CardReport[];
  log: string[];
}

export interface Status {
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
    case 'limiteSessioni': return `limite di sessioni ${r.detail ?? ''}`;
    case 'quota': return `quota: ${r.detail ?? ''}`;
    case 'areaNonMappata': return `area non in config/mappa.json: ${r.detail ?? ''}`;
    default: return r.type;
  }
}
