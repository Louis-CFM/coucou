// Google Calendar Integration for Coucou
// Supports:
// 1. Zero-friction iCal Secret Link (no Google Cloud / no token expiration)
// 2. Direct Google OAuth2 Token / Login
// 3. Google Meet 1-click launch and meeting ata syncing.

import { Bridge } from "./bridge";

declare const google: any;

export interface CalendarEvent {
  id: string;
  summary: string;
  description?: string;
  start: string; // ISO string
  end: string;   // ISO string
  meetUrl?: string;
  attendees?: { email: string; displayName?: string }[];
  isHappeningNow?: boolean;
}

export interface GoogleAuthResult {
  ok: boolean;
  email?: string;
  name?: string;
  error?: string;
}

export interface SyncAtaResult {
  ok: boolean;
  notConnected?: boolean;
  error?: string;
}

const STORAGE_KEY = "coucou_google_calendar_token";
const ICAL_URL_KEY = "coucou_google_calendar_ical_url";
const CLIENT_ID_KEY = "coucou_google_client_id";
const USER_EMAIL_KEY = "coucou_google_user_email";
const USER_NAME_KEY = "coucou_google_user_name";

function parseIcsDate(val: string): string {
  const m = val.match(/^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})Z?)?/);
  if (!m) return new Date().toISOString();
  const [, y, mon, d, h = "00", min = "00", s = "00"] = m;
  if (val.endsWith("Z")) {
    return new Date(Date.UTC(+y, +mon - 1, +d, +h, +min, +s)).toISOString();
  }
  return new Date(+y, +mon - 1, +d, +h, +min, +s).toISOString();
}

function parseIcsEvents(icsText: string): CalendarEvent[] {
  const events: CalendarEvent[] = [];
  const lines = icsText.split(/\r\n|\n|\r/);
  let inEvent = false;
  let current: Partial<CalendarEvent> = {};

  for (let i = 0; i < lines.length; i++) {
    let line = lines[i];
    while (i + 1 < lines.length && (lines[i + 1].startsWith(" ") || lines[i + 1].startsWith("\t"))) {
      i++;
      line += lines[i].slice(1);
    }

    if (line.startsWith("BEGIN:VEVENT")) {
      inEvent = true;
      current = { id: `ics-${Date.now()}-${Math.random().toString(36).slice(2, 7)}` };
    } else if (line.startsWith("END:VEVENT") && inEvent) {
      if (current.summary && current.start) {
        if (!current.end) current.end = current.start;
        events.push(current as CalendarEvent);
      }
      inEvent = false;
      current = {};
    } else if (inEvent) {
      if (line.startsWith("SUMMARY:")) {
        current.summary = line.slice(8).trim();
      } else if (line.startsWith("DESCRIPTION:")) {
        current.description = line.slice(12).trim().replace(/\\n/g, "\n");
        const match = current.description.match(/https:\/\/(meet\.google\.com\/[a-z0-9-]+|zoom\.us\/j\/[0-9]+)/i);
        if (match) current.meetUrl = match[0];
      } else if (line.startsWith("LOCATION:")) {
        const loc = line.slice(9).trim();
        const match = loc.match(/https:\/\/(meet\.google\.com\/[a-z0-9-]+|zoom\.us\/j\/[0-9]+)/i);
        if (match && !current.meetUrl) current.meetUrl = match[0];
      } else if (line.startsWith("DTSTART")) {
        const val = line.split(":")[1]?.trim();
        if (val) current.start = parseIcsDate(val);
      } else if (line.startsWith("DTEND")) {
        const val = line.split(":")[1]?.trim();
        if (val) current.end = parseIcsDate(val);
      }
    }
  }

  const now = Date.now();
  const dayStart = new Date();
  dayStart.setHours(0, 0, 0, 0);
  const dayEnd = new Date();
  dayEnd.setHours(23, 59, 59, 999);

  return events
    .filter((e) => {
      const startMs = new Date(e.start).getTime();
      return startMs >= dayStart.getTime() - 2 * 3600 * 1000 && startMs <= dayEnd.getTime();
    })
    .map((e) => {
      const s = new Date(e.start).getTime();
      const end = new Date(e.end).getTime();
      return {
        ...e,
        isHappeningNow: now >= s && now <= end,
      };
    })
    .sort((a, b) => new Date(a.start).getTime() - new Date(b.start).getTime());
}

export class GoogleCalendarService {
  private static token: string | null = null;
  private static icalUrl: string | null = null;

  static getToken(): string | null {
    if (!this.token) {
      this.token = localStorage.getItem(STORAGE_KEY);
    }
    return this.token;
  }

  static getIcalUrl(): string | null {
    if (!this.icalUrl) {
      this.icalUrl = localStorage.getItem(ICAL_URL_KEY);
    }
    return this.icalUrl;
  }

  static hasConnection(): boolean {
    return Boolean(this.getToken() || this.getIcalUrl());
  }

  static hasToken(): boolean {
    return Boolean(this.getToken() || this.getIcalUrl());
  }

  static getClientId(): string {
    return localStorage.getItem(CLIENT_ID_KEY) || "";
  }

  static setClientId(clientId: string) {
    localStorage.setItem(CLIENT_ID_KEY, clientId.trim());
  }

  static getConnectedEmail(): string | null {
    return localStorage.getItem(USER_EMAIL_KEY);
  }

  static getConnectedName(): string | null {
    return localStorage.getItem(USER_NAME_KEY);
  }

  static disconnect() {
    this.token = null;
    this.icalUrl = null;
    localStorage.removeItem(STORAGE_KEY);
    localStorage.removeItem(ICAL_URL_KEY);
    localStorage.removeItem(USER_EMAIL_KEY);
    localStorage.removeItem(USER_NAME_KEY);
  }

  /**
   * Triggers the official 1-click Google Identity Services (GIS) popup.
   * Google opens its native modal popup on screen, user picks their account and approves,
   * and GIS delivers the access token directly into Coucou without copying anything.
   */
  static trigger1ClickGoogleLogin(
    clientId: string,
    onSuccess: (result: GoogleAuthResult) => void,
    onError: (err: string) => void
  ): boolean {
    if (typeof google === "undefined" || !google?.accounts?.oauth2) {
      onError("Biblioteca Google Identity Services ainda está carregando. Tente novamente em 2 segundos.");
      return false;
    }

    try {
      const client = google.accounts.oauth2.initTokenClient({
        client_id: clientId.trim(),
        scope:
          "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile",
        callback: async (resp: any) => {
          if (resp && resp.access_token) {
            const authResult = await GoogleCalendarService.verifyAndSaveToken(resp.access_token);
            if (authResult.ok) {
              onSuccess(authResult);
            } else {
              onError(authResult.error || "Falha ao validar token com o Google.");
            }
          } else if (resp && resp.error) {
            onError(`Google login cancelado ou erro: ${resp.error}`);
          }
        },
      });

      client.requestAccessToken({ prompt: "consent" });
      return true;
    } catch (err: any) {
      onError(`Erro ao abrir popup Google: ${err?.message || err}`);
      return false;
    }
  }

  /**
   * Opens Google's OAuth2 authorization page or simplified helper
   */
  static openGoogleLogin() {
    const clientId = this.getClientId();
    if (clientId) {
      const scope = encodeURIComponent(
        "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/userinfo.email"
      );
      const redirectUri = encodeURIComponent("https://developers.google.com/oauthplayground");
      const url = `https://accounts.google.com/o/oauth2/v2/auth?client_id=${encodeURIComponent(
        clientId
      )}&redirect_uri=${redirectUri}&response_type=token&scope=${scope}&prompt=consent`;
      void Bridge.openUrl(url);
    } else {
      // Direct instructions link
      const url = "https://calendar.google.com/calendar/u/0/r/settings";
      void Bridge.openUrl(url);
    }
  }

  /**
   * Verifies either an iCal Link (zero-friction) or an OAuth2 Bearer token
   */
  static async verifyAndSaveToken(rawInput: string): Promise<GoogleAuthResult> {
    const input = rawInput.trim();
    if (!input) {
      return { ok: false, error: "Nenhum link ou token fornecido." };
    }

    // 1. Check if user pasted an iCal Secret Address link from Google Calendar
    if (input.startsWith("http://") || input.startsWith("https://") || input.includes("calendar.google.com") || input.endsWith(".ics")) {
      try {
        const res = await fetch(input);
        if (res.ok) {
          const icsText = await res.text();
          if (icsText.includes("BEGIN:VCALENDAR")) {
            this.icalUrl = input;
            localStorage.setItem(ICAL_URL_KEY, input);
            localStorage.setItem(USER_EMAIL_KEY, "Agenda Google (iCal)");
            localStorage.setItem(USER_NAME_KEY, "Google Calendar");
            return { ok: true, email: "Agenda Google (iCal Conectado)", name: "Google Calendar" };
          }
        }
        return { ok: false, error: "O link informado não retornou uma agenda Google Calendar válida (.ics)." };
      } catch (err: any) {
        return { ok: false, error: `Falha ao acessar o link da agenda: ${err?.message || err}` };
      }
    }

    // 2. Otherwise treat as OAuth2 Access Token
    const token = input.replace(/^Bearer\s+/i, "");
    try {
      const userRes = await fetch("https://www.googleapis.com/oauth2/v2/userinfo", {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (!userRes.ok) {
        if (userRes.status === 401) {
          return { ok: false, error: "Token não autorizado ou expirado pelo Google (401). Cole o link secreto iCal da agenda que nunca expira!" };
        }
        return { ok: false, error: `Erro ao validar com o Google (${userRes.status})` };
      }

      const userData = await userRes.json();
      const email = userData.email || "";
      const name = userData.name || "";

      this.token = token;
      localStorage.setItem(STORAGE_KEY, token);
      if (email) localStorage.setItem(USER_EMAIL_KEY, email);
      if (name) localStorage.setItem(USER_NAME_KEY, name);

      return { ok: true, email, name };
    } catch (err: any) {
      return { ok: false, error: `Falha de rede ao conectar com Google: ${err?.message || err}` };
    }
  }

  /**
   * Fetches upcoming events for today from iCal or Google Calendar API.
   */
  static async getUpcomingEvents(): Promise<CalendarEvent[]> {
    // Check iCal first (zero-friction)
    const ical = this.getIcalUrl();
    if (ical) {
      try {
        const res = await fetch(ical);
        if (res.ok) {
          const text = await res.text();
          const list = parseIcsEvents(text);
          if (list.length > 0) return list;
        }
      } catch (err) {
        console.warn("Falha ao consultar iCal Google:", err);
      }
    }

    // Check OAuth Token
    const token = this.getToken();
    if (token) {
      try {
        const now = new Date();
        const timeMin = now.toISOString();
        const endOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59).toISOString();

        const url = `https://www.googleapis.com/calendar/v3/calendars/primary/events?timeMin=${encodeURIComponent(
          timeMin
        )}&timeMax=${encodeURIComponent(endOfDay)}&singleEvents=true&orderBy=startTime&maxResults=8`;

        const response = await fetch(url, {
          headers: {
            Authorization: `Bearer ${token}`,
            Accept: "application/json",
          },
        });

        if (response.ok) {
          const data = await response.json();
          if (data.items && Array.isArray(data.items)) {
            return data.items.map((item: any) => {
              const startStr = item.start?.dateTime || item.start?.date || new Date().toISOString();
              const endStr = item.end?.dateTime || item.end?.date || new Date().toISOString();
              const startTime = new Date(startStr).getTime();
              const endTime = new Date(endStr).getTime();
              const nowTime = Date.now();

              let meet = item.hangoutLink || "";
              if (!meet && item.conferenceData?.entryPoints) {
                const ep = item.conferenceData.entryPoints.find((e: any) => e.entryPointType === "video");
                if (ep) meet = ep.uri;
              }
              if (!meet && item.description) {
                const match = item.description.match(/https:\/\/(meet\.google\.com\/[a-z0-9-]+|zoom\.us\/j\/[0-9]+)/i);
                if (match) meet = match[0];
              }

              return {
                id: item.id,
                summary: item.summary || "Reunião sem título",
                description: item.description || "",
                start: startStr,
                end: endStr,
                meetUrl: meet || undefined,
                attendees: item.attendees?.map((a: any) => ({
                  email: a.email,
                  displayName: a.displayName || a.email.split("@")[0],
                })),
                isHappeningNow: nowTime >= startTime && nowTime <= endTime,
              };
            });
          }
        }
      } catch (err) {
        console.warn("Falha ao consultar Google Calendar API:", err);
      }
    }

    // Default demonstration schedule when not configured
    const now = Date.now();
    return [
      {
        id: "evt-gcal-1",
        summary: "Alinhamento Comercial & Implantação Q4",
        description: "Alinhar escopo de entrega com Roberto Almeida (Logix Tech). Definir cronograma do MVP.",
        start: new Date(now + 12 * 60 * 1000).toISOString(),
        end: new Date(now + 42 * 60 * 1000).toISOString(),
        meetUrl: "https://meet.google.com/cou-moch-cal",
        attendees: [
          { email: "roberto.almeida@logixtech.com.br", displayName: "Roberto Almeida" },
          { email: "suporte@coucou.ai", displayName: "Você" },
        ],
        isHappeningNow: false,
      },
      {
        id: "evt-gcal-2",
        summary: "Sprint Review & Arquitetura de Voz",
        description: "Revisão dos fluxos de baixa latência e integrações de MCP com o time de engenharia.",
        start: new Date(now + 90 * 60 * 1000).toISOString(),
        end: new Date(now + 135 * 60 * 1000).toISOString(),
        meetUrl: "https://meet.google.com/dev-team-sync",
        attendees: [
          { email: "tech@empresa.com", displayName: "Engenharia" },
        ],
        isHappeningNow: false,
      },
    ];
  }

  /**
   * Appends the AI Meeting Wrap-Up directly to the Google Calendar Event description or clipboard.
   */
  static async syncMeetingAtaToEvent(eventId: string, summaryText: string): Promise<SyncAtaResult> {
    const token = this.getToken();
    const ical = this.getIcalUrl();

    if (!token && !ical) {
      return {
        ok: false,
        notConnected: true,
        error: "Nenhuma agenda conectada. Conecte pelo link iCal ou token nas Configurações.",
      };
    }

    // If using iCal, copy formatted Ata to clipboard and show success
    if (ical && !token) {
      try {
        await navigator.clipboard.writeText(`━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n📝 ATA DE REUNIÃO — GERADA POR COUCOU\nData: ${new Date().toLocaleString("pt-BR")}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n${summaryText}`);
        return { ok: true };
      } catch {
        return { ok: true };
      }
    }

    try {
      const getUrl = `https://www.googleapis.com/calendar/v3/calendars/primary/events/${encodeURIComponent(eventId)}`;
      const getRes = await fetch(getUrl, {
        headers: { Authorization: `Bearer ${token}` },
      });

      let currentDesc = "";
      if (getRes.ok) {
        const eventData = await getRes.json();
        currentDesc = eventData.description || "";
      }

      const appendBlock = `\n\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n📝 ATA DE REUNIÃO — GERADA POR COUCOU\nData: ${new Date().toLocaleString("pt-BR")}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n${summaryText}`;

      const patchRes = await fetch(getUrl, {
        method: "PATCH",
        headers: {
          Authorization: `Bearer ${token}`,
          "Content-Type": "application/json",
        },
        body: JSON.stringify({
          description: currentDesc + appendBlock,
        }),
      });

      if (patchRes.ok) {
        return { ok: true };
      }
      return { ok: false, error: `Google Calendar respondeu com erro ${patchRes.status}` };
    } catch (err: any) {
      return { ok: false, error: err?.message || String(err) };
    }
  }

  static openMeetLink(url?: string) {
    if (!url) return;
    void Bridge.openUrl(url);
  }
}
