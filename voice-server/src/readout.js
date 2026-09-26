// Builds the spoken readout for one prescription in one language.
//
// Every sentence is tagged with where it came from:
//   "template" - a hand-written sentence from templates.js (numbers inserted as digits)
//   "grok"     - Grok's translation of label text the templates don't cover
//   "english"  - the original English, read after a Grok translation as a safety check
// The rx number is never read aloud.

import { LANGUAGES } from './templates.js';
import { parseInstructions } from './instructions.js';
import { translate } from './grok.js';

export async function buildReadout(rx, lang, { lastTakenAt, timeZone = 'America/New_York' } = {}) {
  const t = LANGUAGES[lang];
  const sentences = [];
  // (The regex fixes dates that already end in a period, e.g. "8:15 a.m..")
  const add = (text, source = 'template') => sentences.push({ text: text.replace(/\.\.$/, '.'), source });

  // Label text we can't template: English readers hear it as-is; everyone else
  // hears Grok's translation followed by the original English.
  async function addLabelText(heading, english) {
    if (lang === 'en') return add(`${heading} ${english}`);

    const translated = await translate(english, lang);
    if (translated) {
      add(`${heading} ${translated}`, 'grok');
      add(`${t.autoTranslated} ${english}`, 'english');
    } else {
      add(`${heading} ${t.notTranslated} ${english}`, 'english');
    }
  }

  // "Lisinopril, 10 milligrams tablet."
  const strength = spokenStrength(rx.dosage, t);
  add(`${titleCase(rx.drugName)}${strength ? `, ${strength}` : ''}.`);

  // Dose and timing
  const parsed = parseInstructions(rx.instructions);
  if (parsed.understood) {
    add(t.dose(parsed.count, t.forms[parsed.form].count(parsed.count), parsed.byMouth));
    if (parsed.everyHours?.length === 2) add(t.everyRange(...parsed.everyHours));
    else if (parsed.everyHours) add(t.everyHours(parsed.everyHours[0]));
    if (parsed.perDay) add(t.perDay(parsed.perDay));
    if (parsed.asNeeded) add(t.asNeeded);
  } else if (rx.instructions) {
    await addLabelText(t.directions, sentenceCase(rx.instructions));
  }

  const withFood = rx.takeWithFood ?? parsed.withFood;
  if (withFood === true) add(t.withFood);
  if (withFood === false) add(t.emptyStomach);

  const times = [...new Set([...(rx.timesOfDay ?? []), ...parsed.times])].filter((x) => t.times[x]);
  if (times.length) add(t.timesLine(times.map((x) => t.times[x]).join(t.listSeparator)));

  if (lastTakenAt) {
    const when = new Intl.DateTimeFormat(t.locale, {
      month: 'long', day: 'numeric', hour: 'numeric', minute: '2-digit', timeZone,
    }).format(new Date(lastTakenAt));
    add(t.lastTaken(when));
  }

  if (rx.quantity) add(t.quantity(rx.quantity));

  if (rx.expirationDate) {
    // A plain "2027-03-15" is read in UTC so it isn't shifted to the day before.
    const dateOnly = /^\d{4}-\d{2}-\d{2}$/.test(rx.expirationDate);
    const when = new Intl.DateTimeFormat(t.locale, {
      dateStyle: 'long', timeZone: dateOnly ? 'UTC' : timeZone,
    }).format(new Date(rx.expirationDate));
    add(t.expires(when));
  }

  if (rx.sideEffects?.length) {
    await addLabelText(t.warnings, rx.sideEffects.map(sentenceCase).join(' '));
  }

  if (rx.pharmacyName) add(t.pharmacy(rx.pharmacyName));

  return {
    language: lang,
    text: sentences.map((s) => s.text).join(' '),
    sentences,
  };
}

// "10 MG TABLET" -> "10 milligrams tablet" (in the chosen language)
function spokenStrength(dosage, t) {
  if (!dosage) return '';
  const m = dosage.toUpperCase().match(/^(\d+(?:\.\d+)?)\s?(MG|MCG|ML|G)\b\s*(.*)$/);
  if (!m) return dosage.toLowerCase();

  const [, amount, unit, rest] = m;
  const form = rest.startsWith('TAB') ? t.forms.tablet.noun
             : rest.startsWith('CAP') ? t.forms.capsule.noun
             : rest.toLowerCase();
  return [`${amount} ${t.units[unit]}`, form].filter(Boolean).join(' ');
}

const titleCase = (s) => s.toLowerCase().replace(/\b\w/g, (c) => c.toUpperCase());

// "MAY CAUSE DROWSINESS" -> "May cause drowsiness."
function sentenceCase(s) {
  const lower = s.trim().toLowerCase();
  const text = lower.charAt(0).toUpperCase() + lower.slice(1);
  return /[.!?]$/.test(text) ? text : text + '.';
}
