// When a website's domain was registered, from its registry (RDAP).
//
// Scam sites are usually days or weeks old. A registry's record of when a
// domain was first registered cannot be set by whoever runs the site, so
// "registered 4 days ago" is worth saying before a password goes in. An old
// domain proves nothing (one can be bought), so age only ever warns.
//
// Asked only when a login is about to be used or saved on a site it is not
// linked to, never for ordinary fills, and only once the user has turned it
// on in Settings (it is off until then). The question goes straight to the
// registry for the domain's ending (found through IANA's public list), which
// learns which domain was asked about; no third party is in between. Nothing
// else goes with it: no cookies, no referrer, and the answer is kept in
// memory only, so no list of asked-about sites is ever written down.
//
// The same as lib/autofill/domain_age.dart in the app.

const BOOTSTRAP = 'https://data.iana.org/rdap/dns.json';
const TIMEOUT_MS = 5000;
const MAX_BYTES = 512 * 1024;
const DAY = 86_400_000;

/** IANA's bootstrap file: each ending to the first https server listed. */
export function rdapServers(body) {
  let decoded;
  try {
    decoded = JSON.parse(body);
  } catch {
    return null;
  }
  if (!Array.isArray(decoded?.services)) return null;
  const out = new Map();
  for (const service of decoded.services) {
    if (!Array.isArray(service) || !Array.isArray(service[0]) || !Array.isArray(service[1])) continue;
    const url = service[1].find((u) => typeof u === 'string' && u.startsWith('https://'));
    if (!url) continue;
    const base = url.endsWith('/') ? url : `${url}/`;
    for (const ending of service[0]) {
      if (typeof ending === 'string') out.set(ending.toLowerCase(), base);
    }
  }
  return out;
}

/** The registration date in an RDAP domain answer, or null. */
export function registeredIn(body) {
  let decoded;
  try {
    decoded = JSON.parse(body);
  } catch {
    return null;
  }
  if (!Array.isArray(decoded?.events)) return null;
  const event = decoded.events.find((e) => e?.eventAction === 'registration');
  const when = typeof event?.eventDate === 'string' ? new Date(event.eventDate) : null;
  return when && !Number.isNaN(when.getTime()) ? when : null;
}

export const AgeConcern = { danger: 'danger', caution: 'caution', none: 'none' };

export function ageConcern(registered, now) {
  const days = Math.floor((now - registered) / DAY);
  if (days < 30) return AgeConcern.danger;
  if (days < 182) return AgeConcern.caution;
  return AgeConcern.none;
}

/** The warning in words, or null when the age is not worth a mention. */
export function describeAge(site, registered, now) {
  const concern = ageConcern(registered, now);
  if (concern === AgeConcern.none) return null;
  const days = Math.floor((now - registered) / DAY);
  const when = days <= 0 ? 'today'
    : days === 1 ? 'yesterday'
      : days < 14 ? `${days} days ago`
        : days < 60 ? `${Math.floor(days / 7)} weeks ago`
          : `${Math.floor(days / 30)} months ago`;
  return concern === AgeConcern.danger
    ? `${site} was registered ${when}. Scam sites are usually only days old.`
    : `${site} was registered ${when}. New sites deserve a closer look.`;
}

/**
 * Asks registries, remembering answers for as long as the service worker
 * lives. [fetchImpl] is replaced in tests.
 */
export class DomainAge {
  constructor(fetchImpl = (...args) => fetch(...args)) {
    this.fetch = fetchImpl;
    this.servers = null;
    this.answers = new Map();
  }

  /** When [registrable] was registered, or null when the registry does not say. */
  registered(registrable) {
    if (!this.answers.has(registrable)) {
      this.answers.set(registrable, this.#registered(registrable));
    }
    return this.answers.get(registrable);
  }

  async #registered(domain) {
    this.servers ??= this.#get(BOOTSTRAP).then((body) => (body === null ? null : rdapServers(body)));
    const servers = await this.servers;
    if (servers === null) {
      // Try the list again next time rather than remembering a failure.
      this.servers = null;
      this.answers.delete(domain);
      return null;
    }
    const base = servers.get(domain.slice(domain.lastIndexOf('.') + 1));
    if (!base) return null;
    const body = await this.#get(`${base}domain/${domain}`);
    return body === null ? null : registeredIn(body);
  }

  async #get(url) {
    try {
      // Not followed: registries answer directly, and a redirect could hand
      // the question to anyone.
      const response = await this.fetch(url, {
        headers: { Accept: 'application/rdap+json, application/json' },
        redirect: 'error',
        credentials: 'omit',
        referrerPolicy: 'no-referrer',
        cache: 'no-store',
        signal: AbortSignal.timeout(TIMEOUT_MS),
      });
      if (!response.ok) return null;
      const text = await response.text();
      return text.length > MAX_BYTES ? null : text;
    } catch {
      return null;
    }
  }
}
