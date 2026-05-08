import { useEffect, useRef, useState } from 'react';

/**
 * Subscribe to the daemon's SSE event stream (`GET /api/events`).
 *
 * Express has no `/api/events` endpoint — when the daemon isn't running we
 * just get a stream of failed connections, so we cap reconnection attempts
 * and stop trying after the threshold (returning `connected: false`). The
 * Mac/web cutover stays seamless: if `eavd` is up, we deliver pushes; if
 * not, the existing polling keeps working.
 */

export type DaemonEvent =
  | { kind: 'task-changed'; id: string; file: string; pos: number }
  | { kind: 'file-changed'; file: string }
  | { kind: 'clock-changed'; file?: string; pos?: number; clocking: boolean }
  | { kind: 'config-changed' };

interface Options {
  onEvent: (event: DaemonEvent) => void;
  /** Number of consecutive connect failures before giving up. Default: 3. */
  maxConsecutiveFailures?: number;
}

export function useDaemonEvents({ onEvent, maxConsecutiveFailures = 3 }: Options) {
  const [connected, setConnected] = useState(false);
  const handlerRef = useRef(onEvent);
  handlerRef.current = onEvent;

  useEffect(() => {
    let source: EventSource | null = null;
    let retries = 0;
    let abandoned = false;

    function attach() {
      if (abandoned) return;
      try {
        source = new EventSource('/api/events');
      } catch {
        retries += 1;
        if (retries > maxConsecutiveFailures) abandoned = true;
        return;
      }
      const onOpen = () => {
        retries = 0;
        setConnected(true);
      };
      const onError = () => {
        setConnected(false);
        if (source) {
          source.close();
          source = null;
        }
        retries += 1;
        if (retries > maxConsecutiveFailures) {
          abandoned = true;
          return;
        }
        setTimeout(attach, 1000 * retries);
      };

      source.addEventListener('open', onOpen);
      source.addEventListener('error', onError);

      const dispatch = (raw: string) => {
        try {
          const data = JSON.parse(raw);
          handlerRef.current(data as DaemonEvent);
        } catch {
          /* malformed payload — ignore */
        }
      };

      source.addEventListener('task-changed', (e) => dispatch((e as MessageEvent).data));
      source.addEventListener('file-changed', (e) => dispatch((e as MessageEvent).data));
      source.addEventListener('clock-changed', (e) => dispatch((e as MessageEvent).data));
      source.addEventListener('config-changed', (e) => dispatch((e as MessageEvent).data));
    }

    attach();

    return () => {
      abandoned = true;
      if (source) {
        source.close();
        source = null;
      }
      setConnected(false);
    };
  }, [maxConsecutiveFailures]);

  return { connected };
}
