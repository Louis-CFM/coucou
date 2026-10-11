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

const STORAGE_KEY = "coucou_google_calendar_token";

export class GoogleCalendarService {
  private static token: string | null = null;

  static getToken(): string | null {
    if (!this.token) {
      this.token = localStorage.getItem(STORAGE_KEY);
    }
    return this.token;
  }

  static setToken(token: string) {
    this.token = token.trim();
    localStorage.setItem(STORAGE_KEY, this.token);
  }

  static hasToken(): boolean {
    return Boolean(this.getToken());
  }

  static disconnect() {
    this.token = null;
    localStorage.removeItem(STORAGE_KEY);
  }

  /**
   * Fetches upcoming events for today from Google Calendar API.
   * If not connected yet or offline, returns realistic demonstration schedule.
   */
  static async getUpcomingEvents(): Promise<CalendarEvent[]> {
    const token = this.getToken();

    if (token) {
      try {
        const now = new Date();
        const timeMin = now.toISOString();
        const endOfDay = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 23, 59, 59).toISOString();

        const url = `https://www.googleapis.com/calendar/v3/calendars/primary/events?timeMin=${encodeURIComponent(
          timeMin
        )}&timeMax=${encodeURIComponent(endOfDay)}&singleEvents=true&orderBy=startTime&maxResults=5`;

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
        console.warn("Google Calendar API indisponível, usando dados demonstrativos:", err);
      }
    }

    // Default demonstration schedule
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
   * Appends the AI Meeting Wrap-Up directly to the Google Calendar Event description.
   */
  static async syncMeetingAtaToEvent(eventId: string, summaryText: string): Promise<boolean> {
    const token = this.getToken();
    if (!token) {
      console.log(`[Google Calendar Demo] Ata sincronizada no evento ${eventId}:`, summaryText);
      return true;
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

      return patchRes.ok;
    } catch (err) {
      console.error("Erro ao sincronizar ata com Google Calendar:", err);
      return false;
    }
  }

  static openMeetLink(url?: string) {
    if (!url) return;
    window.open(url, "_blank", "noopener,noreferrer");
  }
}
