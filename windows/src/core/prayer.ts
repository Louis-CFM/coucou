// Prayer times, worked out on this PC from the city's position (nothing is
// asked of the Internet). The astronomy is the classic PrayTimes method: the
// sun's declination and the equation of time for the day, then the hour angle
// at which the sun stands at each prayer's angle below the horizon. The Kit's
// Prayer page draws them on the sun's arc (views/kit.ts).

export type PrayerName = "fajr" | "sunrise" | "dhuhr" | "asr" | "maghrib" | "isha";
export const PRAYERS: readonly PrayerName[] = ["fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"];
/** The five prayers (sunrise is shown on the arc, but no reminder rings for it). */
export const FIVE: readonly PrayerName[] = ["fajr", "dhuhr", "asr", "maghrib", "isha"];

export type MethodId = "karachi" | "mwl" | "isna" | "egypt" | "makkah" | "tehran" | "kemenag" | "jakim" | "diyanet" | "gulf" | "uoif";

interface Method {
  fajr: number;
  /** Degrees below the horizon, or minutes after maghrib. */
  isha: { deg: number } | { min: number };
  /** Degrees for maghrib (Tehran); otherwise sunset. */
  maghribDeg?: number;
}

export const METHODS: Record<MethodId, Method> = {
  karachi: { fajr: 18, isha: { deg: 18 } },
  mwl: { fajr: 18, isha: { deg: 17 } },
  isna: { fajr: 15, isha: { deg: 15 } },
  egypt: { fajr: 19.5, isha: { deg: 17.5 } },
  makkah: { fajr: 18.5, isha: { min: 90 } },
  tehran: { fajr: 17.7, isha: { deg: 14 }, maghribDeg: 4.5 },
  kemenag: { fajr: 20, isha: { deg: 18 } },
  jakim: { fajr: 20, isha: { deg: 18 } },
  diyanet: { fajr: 18, isha: { deg: 17 } },
  gulf: { fajr: 18.2, isha: { deg: 18.2 } },
  uoif: { fajr: 12, isha: { deg: 12 } },
};

export const METHOD_NAMES: Record<MethodId, string> = {
  karachi: "University of Islamic Sciences, Karachi",
  mwl: "Muslim World League",
  isna: "ISNA (North America)",
  egypt: "Egyptian General Authority",
  makkah: "Umm al-Qura, Makkah",
  tehran: "Institute of Geophysics, Tehran",
  kemenag: "Kemenag (Indonesia)",
  jakim: "JAKIM (Malaysia)",
  diyanet: "Diyanet (Türkiye)",
  gulf: "Gulf region",
  uoif: "UOIF (France)",
};

export type AsrSchool = "standard" | "hanafi";

export interface City {
  name: string;
  country: string;
  lat: number;
  lng: number;
  method: MethodId;
  /** Hanafi Asr by default here (South Asia, Central Asia, Türkiye). */
  hanafi?: boolean;
}

// ── Astronomy (degrees in, degrees out) ──────────────────────────────────────

const rad = (d: number) => (d * Math.PI) / 180;
const deg = (r: number) => (r * 180) / Math.PI;
const sin = (d: number) => Math.sin(rad(d));
const cos = (d: number) => Math.cos(rad(d));
const tan = (d: number) => Math.tan(rad(d));
const arcsin = (x: number) => deg(Math.asin(x));
const arccos = (x: number) => deg(Math.acos(x));
const arctan2 = (y: number, x: number) => deg(Math.atan2(y, x));
const arccot = (x: number) => deg(Math.atan(1 / x));
const fix = (a: number, b: number) => {
  const r = a - b * Math.floor(a / b);
  return r < 0 ? r + b : r;
};

function julian(year: number, month: number, day: number): number {
  if (month <= 2) {
    year -= 1;
    month += 12;
  }
  const A = Math.floor(year / 100);
  const B = 2 - A + Math.floor(A / 4);
  return Math.floor(365.25 * (year + 4716)) + Math.floor(30.6001 * (month + 1)) + day + B - 1524.5;
}

function sunPosition(jd: number): { decl: number; eqt: number } {
  const D = jd - 2451545.0;
  const g = fix(357.529 + 0.98560028 * D, 360);
  const q = fix(280.459 + 0.98564736 * D, 360);
  const L = fix(q + 1.915 * sin(g) + 0.02 * sin(2 * g), 360);
  const e = 23.439 - 0.00000036 * D;
  const RA = arctan2(cos(e) * sin(L), cos(L)) / 15;
  const eqt = q / 15 - fix(RA, 24);
  const decl = arcsin(sin(e) * sin(L));
  return { decl, eqt };
}

/**
 * The day's times for a place, in hours after local midnight of that date
 * (`tz` = the offset from UTC in hours). NaN where the sun never reaches the
 * angle (far north in summer): see prayerTimes for the fallback.
 */
export function dayHours(
  date: { y: number; m: number; d: number }, lat: number, lng: number, tz: number, methodId: MethodId, asr: AsrSchool,
): Record<PrayerName, number> {
  const method = METHODS[methodId];
  const jDate = julian(date.y, date.m, date.d) - lng / (15 * 24);
  const midDay = (t: number) => fix(12 - sunPosition(jDate + t / 24).eqt, 24);
  const angleTime = (angle: number, t: number, ccw: boolean) => {
    const decl = sunPosition(jDate + t / 24).decl;
    const noon = midDay(t);
    const h = arccos((-sin(angle) - sin(decl) * sin(lat)) / (cos(decl) * cos(lat))) / 15;
    return noon + (ccw ? -h : h);
  };
  const asrTime = (factor: number, t: number) => {
    const decl = sunPosition(jDate + t / 24).decl;
    return angleTime(-arccot(factor + tan(Math.abs(lat - decl))), t, false);
  };
  // Two passes: the first guesses each time, the second works from the guess.
  let t: Record<PrayerName, number> = { fajr: 5, sunrise: 6, dhuhr: 12, asr: 13, maghrib: 18, isha: 18 };
  for (let pass = 0; pass < 2; pass++) {
    const isha = "deg" in method.isha ? angleTime(method.isha.deg, t.isha, false) : NaN;
    t = {
      fajr: angleTime(method.fajr, t.fajr, true),
      sunrise: angleTime(0.833, t.sunrise, true),
      dhuhr: midDay(t.dhuhr),
      asr: asrTime(asr === "hanafi" ? 2 : 1, t.asr),
      maghrib: angleTime(method.maghribDeg ?? 0.833, t.maghrib, false),
      isha,
    };
  }
  const shift = tz - lng / 15;
  const out = {} as Record<PrayerName, number>;
  for (const p of PRAYERS) out[p] = t[p] + shift;
  if ("min" in method.isha) out.isha = out.maghrib + method.isha.min / 60;
  // The night-portion rule where an angle is never reached.
  const night = 24 - (out.maghrib - out.sunrise);
  if (!Number.isFinite(out.fajr)) out.fajr = out.sunrise - (method.fajr / 60) * night;
  if (!Number.isFinite(out.isha) && "deg" in method.isha) out.isha = out.maghrib + (method.isha.deg / 60) * night;
  return out;
}

/** The day's times, as epoch ms, for the local date of `day` (this PC's time zone). */
export function prayerTimes(day: number, lat: number, lng: number, methodId: MethodId, asr: AsrSchool): Record<PrayerName, number> {
  const d = new Date(day);
  const midnight = new Date(d.getFullYear(), d.getMonth(), d.getDate()).getTime();
  const tz = -new Date(midnight + 12 * 3_600_000).getTimezoneOffset() / 60;
  const hours = dayHours({ y: d.getFullYear(), m: d.getMonth() + 1, d: d.getDate() }, lat, lng, tz, methodId, asr);
  const out = {} as Record<PrayerName, number>;
  // Rounded to the minute, as every timetable shows them.
  for (const p of PRAYERS) out[p] = midnight + Math.round(hours[p] * 60) * 60_000;
  return out;
}

export interface NextPrayer {
  name: PrayerName;
  at: number;
  /** The one before it (for the bar from it to this one). */
  prev: { name: PrayerName; at: number };
}

/** The next of the five after `now` (tomorrow's Fajr after Isha). */
export function nextPrayer(now: number, lat: number, lng: number, methodId: MethodId, asr: AsrSchool): NextPrayer {
  const today = prayerTimes(now, lat, lng, methodId, asr);
  const list = FIVE.map((name) => ({ name, at: today[name] }));
  const i = list.findIndex((p) => p.at > now);
  if (i > 0) return { ...list[i], prev: list[i - 1] };
  if (i === 0) {
    const y = prayerTimes(now - 86_400_000, lat, lng, methodId, asr);
    return { ...list[0], prev: { name: "isha", at: y.isha } };
  }
  const tomorrow = prayerTimes(now + 86_400_000, lat, lng, methodId, asr);
  return { name: "fajr", at: tomorrow.fajr, prev: list[list.length - 1] };
}

/** "in 1 h 8 min" without the words: [hours, minutes] left, rounded up to the minute. */
export function untilParts(ms: number): [number, number] {
  const min = Math.max(0, Math.ceil(ms / 60_000));
  return [Math.floor(min / 60), min % 60];
}

/**
 * Where a moment sits on the day's sun arc, 0 at sunrise … 1 at sunset (below
 * 0 or above 1 at night). The arc's height there is sin(π·x).
 */
export function arcPosition(at: number, times: Record<PrayerName, number>): number {
  return (at - times.sunrise) / Math.max(1, times.maghrib - times.sunrise);
}

// ── Cities ────────────────────────────────────────────────────────────────────

export const CITIES: readonly City[] = [
  // Pakistan
  { name: "Karachi", country: "Pakistan", lat: 24.8607, lng: 67.0011, method: "karachi", hanafi: true },
  { name: "Lahore", country: "Pakistan", lat: 31.5204, lng: 74.3587, method: "karachi", hanafi: true },
  { name: "Islamabad", country: "Pakistan", lat: 33.6844, lng: 73.0479, method: "karachi", hanafi: true },
  { name: "Rawalpindi", country: "Pakistan", lat: 33.5651, lng: 73.0169, method: "karachi", hanafi: true },
  { name: "Faisalabad", country: "Pakistan", lat: 31.4504, lng: 73.135, method: "karachi", hanafi: true },
  { name: "Multan", country: "Pakistan", lat: 30.1575, lng: 71.5249, method: "karachi", hanafi: true },
  { name: "Peshawar", country: "Pakistan", lat: 34.0151, lng: 71.5249, method: "karachi", hanafi: true },
  { name: "Quetta", country: "Pakistan", lat: 30.1798, lng: 66.975, method: "karachi", hanafi: true },
  { name: "Hyderabad", country: "Pakistan", lat: 25.396, lng: 68.3578, method: "karachi", hanafi: true },
  { name: "Gujranwala", country: "Pakistan", lat: 32.1877, lng: 74.1945, method: "karachi", hanafi: true },
  { name: "Sialkot", country: "Pakistan", lat: 32.4945, lng: 74.5229, method: "karachi", hanafi: true },
  { name: "Bahawalpur", country: "Pakistan", lat: 29.3956, lng: 71.6836, method: "karachi", hanafi: true },
  { name: "Sargodha", country: "Pakistan", lat: 32.0836, lng: 72.6711, method: "karachi", hanafi: true },
  { name: "Sukkur", country: "Pakistan", lat: 27.7052, lng: 68.8574, method: "karachi", hanafi: true },
  { name: "Abbottabad", country: "Pakistan", lat: 34.1688, lng: 73.2215, method: "karachi", hanafi: true },
  { name: "Mardan", country: "Pakistan", lat: 34.1986, lng: 72.0404, method: "karachi", hanafi: true },
  { name: "Gujrat", country: "Pakistan", lat: 32.5736, lng: 74.0789, method: "karachi", hanafi: true },
  { name: "Muzaffarabad", country: "Pakistan", lat: 34.37, lng: 73.4711, method: "karachi", hanafi: true },
  // South and Central Asia
  { name: "Delhi", country: "India", lat: 28.6139, lng: 77.209, method: "karachi", hanafi: true },
  { name: "Mumbai", country: "India", lat: 19.076, lng: 72.8777, method: "karachi", hanafi: true },
  { name: "Hyderabad", country: "India", lat: 17.385, lng: 78.4867, method: "karachi", hanafi: true },
  { name: "Lucknow", country: "India", lat: 26.8467, lng: 80.9462, method: "karachi", hanafi: true },
  { name: "Kolkata", country: "India", lat: 22.5726, lng: 88.3639, method: "karachi", hanafi: true },
  { name: "Srinagar", country: "India", lat: 34.0837, lng: 74.7973, method: "karachi", hanafi: true },
  { name: "Dhaka", country: "Bangladesh", lat: 23.8103, lng: 90.4125, method: "karachi", hanafi: true },
  { name: "Chittagong", country: "Bangladesh", lat: 22.3569, lng: 91.7832, method: "karachi", hanafi: true },
  { name: "Kabul", country: "Afghanistan", lat: 34.5553, lng: 69.2075, method: "karachi", hanafi: true },
  { name: "Tashkent", country: "Uzbekistan", lat: 41.2995, lng: 69.2401, method: "mwl", hanafi: true },
  { name: "Almaty", country: "Kazakhstan", lat: 43.222, lng: 76.8512, method: "mwl", hanafi: true },
  // Middle East and Africa
  { name: "Makkah", country: "Saudi Arabia", lat: 21.3891, lng: 39.8579, method: "makkah" },
  { name: "Madinah", country: "Saudi Arabia", lat: 24.5247, lng: 39.5692, method: "makkah" },
  { name: "Riyadh", country: "Saudi Arabia", lat: 24.7136, lng: 46.6753, method: "makkah" },
  { name: "Jeddah", country: "Saudi Arabia", lat: 21.4858, lng: 39.1925, method: "makkah" },
  { name: "Dubai", country: "United Arab Emirates", lat: 25.2048, lng: 55.2708, method: "gulf" },
  { name: "Abu Dhabi", country: "United Arab Emirates", lat: 24.4539, lng: 54.3773, method: "gulf" },
  { name: "Doha", country: "Qatar", lat: 25.2854, lng: 51.531, method: "gulf" },
  { name: "Kuwait City", country: "Kuwait", lat: 29.3759, lng: 47.9774, method: "gulf" },
  { name: "Manama", country: "Bahrain", lat: 26.2285, lng: 50.586, method: "gulf" },
  { name: "Muscat", country: "Oman", lat: 23.588, lng: 58.3829, method: "gulf" },
  { name: "Tehran", country: "Iran", lat: 35.6892, lng: 51.389, method: "tehran" },
  { name: "Baghdad", country: "Iraq", lat: 33.3152, lng: 44.3661, method: "mwl" },
  { name: "Amman", country: "Jordan", lat: 31.9539, lng: 35.9106, method: "mwl" },
  { name: "Jerusalem", country: "Palestine", lat: 31.7683, lng: 35.2137, method: "mwl" },
  { name: "Damascus", country: "Syria", lat: 33.5138, lng: 36.2765, method: "mwl" },
  { name: "Beirut", country: "Lebanon", lat: 33.8938, lng: 35.5018, method: "mwl" },
  { name: "Istanbul", country: "Türkiye", lat: 41.0082, lng: 28.9784, method: "diyanet", hanafi: true },
  { name: "Ankara", country: "Türkiye", lat: 39.9334, lng: 32.8597, method: "diyanet", hanafi: true },
  { name: "Cairo", country: "Egypt", lat: 30.0444, lng: 31.2357, method: "egypt" },
  { name: "Alexandria", country: "Egypt", lat: 31.2001, lng: 29.9187, method: "egypt" },
  { name: "Casablanca", country: "Morocco", lat: 33.5731, lng: -7.5898, method: "mwl" },
  { name: "Algiers", country: "Algeria", lat: 36.7538, lng: 3.0588, method: "mwl" },
  { name: "Tunis", country: "Tunisia", lat: 36.8065, lng: 10.1815, method: "mwl" },
  { name: "Khartoum", country: "Sudan", lat: 15.5007, lng: 32.5599, method: "egypt" },
  { name: "Lagos", country: "Nigeria", lat: 6.5244, lng: 3.3792, method: "mwl" },
  { name: "Kano", country: "Nigeria", lat: 12.0022, lng: 8.592, method: "mwl" },
  { name: "Nairobi", country: "Kenya", lat: -1.2921, lng: 36.8219, method: "mwl" },
  { name: "Mogadishu", country: "Somalia", lat: 2.0469, lng: 45.3182, method: "mwl" },
  { name: "Dakar", country: "Senegal", lat: 14.7167, lng: -17.4677, method: "mwl" },
  { name: "Johannesburg", country: "South Africa", lat: -26.2041, lng: 28.0473, method: "mwl" },
  // South-East Asia
  { name: "Jakarta", country: "Indonesia", lat: -6.2088, lng: 106.8456, method: "kemenag" },
  { name: "Surabaya", country: "Indonesia", lat: -7.2575, lng: 112.7521, method: "kemenag" },
  { name: "Bandung", country: "Indonesia", lat: -6.9175, lng: 107.6191, method: "kemenag" },
  { name: "Kuala Lumpur", country: "Malaysia", lat: 3.139, lng: 101.6869, method: "jakim" },
  { name: "Singapore", country: "Singapore", lat: 1.3521, lng: 103.8198, method: "jakim" },
  { name: "Bandar Seri Begawan", country: "Brunei", lat: 4.9031, lng: 114.9398, method: "jakim" },
  // Europe, the Americas, Oceania
  { name: "London", country: "United Kingdom", lat: 51.5074, lng: -0.1278, method: "mwl" },
  { name: "Birmingham", country: "United Kingdom", lat: 52.4862, lng: -1.8904, method: "mwl" },
  { name: "Manchester", country: "United Kingdom", lat: 53.4808, lng: -2.2426, method: "mwl" },
  { name: "Paris", country: "France", lat: 48.8566, lng: 2.3522, method: "uoif" },
  { name: "Berlin", country: "Germany", lat: 52.52, lng: 13.405, method: "mwl" },
  { name: "Amsterdam", country: "Netherlands", lat: 52.3676, lng: 4.9041, method: "mwl" },
  { name: "Brussels", country: "Belgium", lat: 50.8503, lng: 4.3517, method: "mwl" },
  { name: "Madrid", country: "Spain", lat: 40.4168, lng: -3.7038, method: "mwl" },
  { name: "Rome", country: "Italy", lat: 41.9028, lng: 12.4964, method: "mwl" },
  { name: "Stockholm", country: "Sweden", lat: 59.3293, lng: 18.0686, method: "mwl" },
  { name: "Oslo", country: "Norway", lat: 59.9139, lng: 10.7522, method: "mwl" },
  { name: "Moscow", country: "Russia", lat: 55.7558, lng: 37.6173, method: "mwl" },
  { name: "Kazan", country: "Russia", lat: 55.7963, lng: 49.1088, method: "mwl", hanafi: true },
  { name: "Sarajevo", country: "Bosnia and Herzegovina", lat: 43.8563, lng: 18.4131, method: "mwl", hanafi: true },
  { name: "New York", country: "United States", lat: 40.7128, lng: -74.006, method: "isna" },
  { name: "Chicago", country: "United States", lat: 41.8781, lng: -87.6298, method: "isna" },
  { name: "Houston", country: "United States", lat: 29.7604, lng: -95.3698, method: "isna" },
  { name: "Los Angeles", country: "United States", lat: 34.0522, lng: -118.2437, method: "isna" },
  { name: "Toronto", country: "Canada", lat: 43.6532, lng: -79.3832, method: "isna" },
  { name: "Mexico City", country: "Mexico", lat: 19.4326, lng: -99.1332, method: "isna" },
  { name: "São Paulo", country: "Brazil", lat: -23.5505, lng: -46.6333, method: "mwl" },
  { name: "Sydney", country: "Australia", lat: -33.8688, lng: 151.2093, method: "mwl" },
  { name: "Melbourne", country: "Australia", lat: -37.8136, lng: 144.9631, method: "mwl" },
  { name: "Auckland", country: "New Zealand", lat: -36.8485, lng: 174.7633, method: "mwl" },
];

/** Cities whose name or country starts a word with what was typed. */
export function findCities(query: string, limit = 8): City[] {
  const q = query.trim().toLowerCase();
  if (!q) return CITIES.slice(0, limit);
  const words = (s: string) => s.toLowerCase().split(/[\s,-]+/);
  return CITIES.filter((c) => [...words(c.name), ...words(c.country)].some((w) => w.startsWith(q)) || c.name.toLowerCase().startsWith(q))
    .slice(0, limit);
}
