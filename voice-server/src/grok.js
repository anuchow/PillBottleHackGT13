// Grok (xAI) translates label text our templates don't cover,
// such as warning stickers or "TAKE 1 TABLET AS NEEDED FOR PAIN".
//
// Safety check: every number in the English must appear in the translation.
// If Grok drops or changes a number, we throw its answer away and read the English.

import { LANGUAGES } from './templates.js';
import { db } from './db.js';

export async function translate(english, lang) {
  const saved = await loadSaved(english, lang);
  if (saved) return saved;

  if (!process.env.XAI_API_KEY) return null;

  const model = process.env.XAI_MODEL || 'grok-4.3';
  try {
    const res = await fetch('https://api.x.ai/v1/chat/completions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${process.env.XAI_API_KEY}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        model,
        temperature: 0,
        messages: [
          {
            role: 'system',
            content:
              `Translate text from a US prescription label into ${LANGUAGES[lang].name}. ` +
              'Keep every number exactly as written, using the digits 0-9. ' +
              'Keep drug names in English. Do not add, remove, or explain anything. ' +
              'Reply with the translation only.',
          },
          { role: 'user', content: english },
        ],
      }),
    });
    if (!res.ok) throw new Error(`xAI ${res.status}: ${await res.text()}`);

    const data = await res.json();
    const translated = data.choices[0].message.content.trim();

    if (!sameNumbers(english, translated)) {
      console.warn(`Grok changed a number, using English instead: "${english}" -> "${translated}"`);
      return null;
    }
    await save(english, lang, translated, model);
    return translated;
  } catch (err) {
    console.error('Grok translation failed:', err.message);
    return null;
  }
}

// Translations are saved in the Tiger `translations` table, so each label line
// is only sent to Grok once per language. Database errors never block the readout.
async function loadSaved(english, lang) {
  if (!db) return null;
  try {
    const { rows } = await db.query(
      'SELECT translated_text FROM translations WHERE source_text = $1 AND language = $2',
      [english, lang]
    );
    return rows[0]?.translated_text ?? null;
  } catch (err) {
    console.error('Could not read saved translation:', err.message);
    return null;
  }
}

async function save(english, lang, translated, model) {
  if (!db) return;
  try {
    await db.query(
      `INSERT INTO translations (source_text, language, translated_text, model)
       VALUES ($1, $2, $3, $4) ON CONFLICT DO NOTHING`,
      [english, lang, translated, model]
    );
  } catch (err) {
    console.error('Could not save translation:', err.message);
  }
}

function sameNumbers(a, b) {
  const numbers = (s) => (s.match(/\d+(\.\d+)?/g) ?? []).sort().join(',');
  return numbers(a) === numbers(b);
}
