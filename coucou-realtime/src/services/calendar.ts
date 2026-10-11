// Google Calendar API Integration for Coucou Realtime Dashboard
// Enables automatic upcoming meeting detection, 1-click Google Meet launch, and calendar note syncing.

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
const CLIENT_ID_KEY = "coucou_google_client_id";
const USER_EMAIL_KEY = "coucou_google_user_email";
const USER_NAME_KEY = "coucou_google_user_name";

export class GoogleCalendarService {
  private static token: string | null = null;

  static getToken(): string | null {
    if (!this.token) {
      this.token = localStorage.getItem(STORAGE_KEY);
    }
    return this.token;
  }

  static setToken(token: string) {
    this.token = token.trim().replace(/^Bearer\s+/i, "");
    localStorage.setItem(STORAGE_KEY, this.token);
  }

  static hasToken(): boolean {
    return Boolean(this.getToken());
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
    localStorage.removeItem(STORAGE_KEY);
    localStorage.removeItem(USER_EMAIL_KEY);
    localStorage.removeItem(USER_NAME_KEY);
  }

  static openGoogleLogin() {
    const clientId = this.getClientId();
    if (clientId) {
      const scope = encodeURIComponent(
        "https://www.googleapis.com/auth/calendar.events https://www.googleapis.com/auth/calendar.readonly https://www.googleapis.com/auth/userinfo.email https://www.googleapis.com/auth/userinfo.profile"
      );
      const redirectUri = encodeURIComponent("https://developers.google.com/oauthplayground");
      const url = `https://accounts.google.com/o/oauth2/v2/auth?client_id=${encodeURIComponent(
        clientId
      )}&redirect_uri=${redirectUri}&response_type=token&scope=${scope}&prompt=consent`;
      window.open(url, "_blank");
    } else {
      const url =
        "https://developers.google.com/oauthplayground/#scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.events%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcalendar.readonly%20https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fuserinfo.email";
      window.open(url, "_blank");
    }
  }

  static async verifyAndSaveToken(rawToken: string): Promise<GoogleAuthResult> {
    const token = rawToken.trim().replace(/^Bearer\s+/i, "");
    if (!token) {
      return { ok: false, error: "Nenhum token fornecido." };
    }

    try {
      const userRes = await fetch("https://www.googleapis.com/oauth2/v2/userinfo", {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (!userRes.ok) {
        if (userRes.status === 401) {
          return { ok: false, error: "Token não autorizado ou expirado pelo Google (401). Gere um novo token." };
        }
        return { ok: false, error: `Erro ao validar com o Google (${userRes.status})` };
      }

      const userData = await userRes.json();
      const email = userData.email || "";
      const name = userData.name || "";

      const calRes = await fetch("https://www.googleapis.com/calendar/v3/calendars/primary", {
        headers: { Authorization: `Bearer ${token}` },
      });

      if (!calRes.ok) {
        return {
          ok: false,
          error: "Conta Google conectou, mas o token não tem permissão para o Google Calendar.",
        };
      }

      this.token = token;
      localStorage.setItem(STORAGE_KEY, token);
      if (email) localStorage.setItem(USER_EMAIL_KEY, email);
      if (name) localStorage.setItem(USER_NAME_KEY, name);

      return { ok: true, email, name };
    } catch (err: any) {
      return { ok: false, error: `Falha de rede ao conectar com Google: ${err?.message || err}` };
    }
  }

  static async getUpcomingEvents(): Promise<CalendarEvent[]> {
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
        } else if (response.status === 401) {
          this.disconnect();
        }
      } catch (err) {
        console.warn("Falha ao consultar Google Calendar API:", err);
      }
    }

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

  static async syncMeetingAtaToEvent(eventId: string, summaryText: string): Promise<SyncAtaResult> {
    const token = this.getToken();
    if (!token) {
      return {
        ok: false,
        notConnected: true,
        error: "Nenhuma conta Google conectada. Clique em 'Logar com o Google' para sincronizar com sua agenda real.",
      };
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
      } else if (getRes.status === 404) {
        const createRes = await fetch("https://www.googleapis.com/calendar/v3/calendars/primary/events", {
          method: "POST",
          headers: {
            Authorization: `Bearer ${token}`,
            "Content-Type": "application/json",
          },
          body: JSON.stringify({
            summary: "Reunião Gravada no Coucou — Ata de Reunião",
            description: `━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n📝 ATA DE REUNIÃO — GERADA POR COUCOU\nData: ${new Date().toLocaleString("pt-BR")}\n━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n${summaryText}`,
            start: { dateTime: new Date(Date.now() - 30 * 60 * 1000).toISOString() },
            end: { dateTime: new Date().toISOString() },
          }),
        });
        if (createRes.ok) {
          return { ok: true };
        }
        return { ok: false, error: "Falha ao criar evento no Google Calendar" };
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
      return { ok: false, error: `Google Calendar retornou status ${patchRes.status}` };
    } catch (err: any) {
      return { ok: false, error: err?.message || String(err) };
    }
  }

  static openMeetLink(url?: string) {
    if (!url) return;
    window.open(url, "_blank", "noopener,noreferrer");
  }
}
