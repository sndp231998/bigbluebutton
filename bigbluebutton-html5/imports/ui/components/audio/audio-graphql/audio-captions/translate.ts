// T-Meet: live caption translation through the self-hosted tmeet-translate service.
import { useEffect, useRef, useState } from 'react';
import Auth from '/imports/ui/services/auth';
import logger from '/imports/startup/client/logger';

const ENDPOINT = '/tmeet-translate/translate';
// Wait for the speaker to pause before translating a growing caption...
const DEBOUNCE_MS = 500;
// ...but never leave a caption untranslated for longer than this while they keep talking.
const MAX_WAIT_MS = 1800;

const cache = new Map<string, string>();
const inFlight = new Map<string, Promise<string>>();

export const languageOf = (locale?: string | null) => (locale || '').split('-')[0].toLowerCase();

export const translateText = (text: string, source: string, target: string): Promise<string> => {
  const key = `${languageOf(source)}|${languageOf(target)}|${text}`;
  const cached = cache.get(key);
  if (cached !== undefined) return Promise.resolve(cached);
  const pending = inFlight.get(key);
  if (pending) return pending;

  const request = fetch(ENDPOINT, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'x-session-token': Auth.sessionToken ?? '',
    },
    body: JSON.stringify({ text, source, target }),
  })
    .then((res) => {
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      return res.json();
    })
    .then((data: { text: string }) => {
      cache.set(key, data.text);
      return data.text;
    })
    .finally(() => inFlight.delete(key));

  inFlight.set(key, request);
  return request;
};

interface TranslatableCaption {
  captionId: string;
  captionText: string;
  locale?: string;
}

// Returns captionId -> translated text for captions spoken in another language than
// `target`. While a caption is still growing, the last translation is kept on screen.
export const useCaptionTranslations = (captions: TranslatableCaption[], target: string) => {
  const [translations, setTranslations] = useState<Record<string, string>>({});
  const timers = useRef<Record<string, ReturnType<typeof setTimeout>>>({});
  const waitingSince = useRef<Record<string, number>>({});
  const lastSeen = useRef<Record<string, string>>({});

  useEffect(() => {
    const now = Date.now();
    captions.forEach(({ captionId, captionText, locale }) => {
      if (!captionText || !locale || languageOf(locale) === languageOf(target)) return;
      // Re-renders hand us the same captions again; only react to new text.
      const seenKey = `${target}|${captionText}`;
      if (lastSeen.current[captionId] === seenKey) return;
      lastSeen.current[captionId] = seenKey;

      const run = () => {
        delete timers.current[captionId];
        delete waitingSince.current[captionId];
        translateText(captionText, locale, target)
          .then((text) => setTranslations((prev) => ({ ...prev, [captionId]: text })))
          .catch((e) => {
            logger.warn({
              logCode: 'tmeet_caption_translate_failed',
              extraInfo: { errorMessage: e.message },
            }, `Caption translation failed: ${e.message}`);
          });
      };

      if (timers.current[captionId]) clearTimeout(timers.current[captionId]);
      if (!waitingSince.current[captionId]) waitingSince.current[captionId] = now;

      if (now - waitingSince.current[captionId] >= MAX_WAIT_MS) {
        run();
      } else {
        timers.current[captionId] = setTimeout(run, DEBOUNCE_MS);
      }
    });
  }, [captions, target]);

  useEffect(() => () => Object.values(timers.current).forEach(clearTimeout), []);

  // Forget translations made for another target language.
  useEffect(() => setTranslations({}), [target]);

  return translations;
};

export default {
  translateText,
  useCaptionTranslations,
  languageOf,
};
