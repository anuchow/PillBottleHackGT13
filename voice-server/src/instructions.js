// Pulls the dose and timing out of label directions such as
// "TAKE 1 TABLET BY MOUTH EVERY 8 HOURS AS NEEDED".
//
// Each phrase we recognize is removed from the text. If anything is left over
// (e.g. "FOR PAIN", "FOR 10 DAYS"), `understood` is false and the readout sends
// the whole direction to Grok instead of reading a partial, possibly wrong, version.

const WORD_NUMBERS = { ONE: 1, TWO: 2, THREE: 3, FOUR: 4 };
const toNumber = (s) => WORD_NUMBERS[s] ?? Number(s);

export function parseInstructions(raw) {
  const result = { understood: false, times: [] };
  if (!raw) return result;

  let text = ' ' + raw.toUpperCase().replace(/[.,;]/g, ' ').replace(/\s+/g, ' ') + ' ';

  // Finds a phrase, removes it from `text`, and returns the regex match.
  function take(regex) {
    const m = text.match(regex);
    if (m) text = text.replace(m[0], ' ');
    return m;
  }

  // "TAKE 1 TABLET", "TAKE TWO CAPSULES"
  const amount = take(/ TAKE (\d+|ONE|TWO|THREE|FOUR) (TABLETS?|TABS?|CAPSULES?|CAPS?) /);
  if (amount) {
    result.count = toNumber(amount[1]);
    result.form = amount[2].startsWith('CAP') ? 'capsule' : 'tablet';
  }

  if (take(/ (BY MOUTH|ORALLY) /)) result.byMouth = true;

  // "EVERY 4 TO 6 HOURS" must be checked before "EVERY 6 HOURS".
  const range = take(/ EVERY (\d+) ?(?:TO|-) ?(\d+) HOURS? /);
  const every = !range && take(/ EVERY (\d+) HOURS? /);
  if (range) result.everyHours = [Number(range[1]), Number(range[2])];
  if (every) result.everyHours = [Number(every[1])];

  // "TWICE DAILY", "3 TIMES A DAY", then plain "DAILY".
  const perDay = take(/ (ONCE|TWICE|(\d+|THREE|FOUR) TIMES) (?:A DAY|DAILY|PER DAY|EVERY DAY) /);
  if (perDay) {
    result.perDay = perDay[1] === 'ONCE' ? 1 : perDay[1] === 'TWICE' ? 2 : toNumber(perDay[2]);
  } else if (take(/ (DAILY|EVERY DAY) /)) {
    result.perDay = 1;
  }

  if (take(/ (AS NEEDED|PRN) /)) result.asNeeded = true;

  if (take(/ WITH (FOOD|MEALS?|A MEAL) /)) result.withFood = true;
  else if (take(/ (ON AN EMPTY STOMACH|WITHOUT FOOD) /)) result.withFood = false;

  // Times of day are read from the prescription's timesOfDay list; we just note them here.
  const timeWords = [
    [/ (IN THE )?MORNING /, 'morning'],
    [/ (AT )?(NOON|LUNCH) /, 'midday'],
    [/ (IN THE )?EVENING /, 'evening'],
    [/ (AT BEDTIME|AT NIGHT|NIGHTLY) /, 'bedtime'],
  ];
  for (const [regex, name] of timeWords) {
    if (take(regex)) result.times.push(name);
  }

  const leftover = text.replace(/\bAND\b/g, '').trim();
  result.understood = Boolean(amount) && leftover === '';
  return result;
}
