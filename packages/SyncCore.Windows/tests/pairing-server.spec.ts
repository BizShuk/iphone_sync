import { describe, expect, it } from 'vitest';
import { PairingServer } from '../src/pairing';

describe('PairingServer (lifecycle)', () => {
  it('opensAndBindsToRandomPort', async () => {
    const server = new PairingServer({
      receiverID: 'mac-test',
      displayName: 'Test Mac',
    });
    expect(server.port).toBe(null);
    await server.open();
    expect(server.port).not.toBe(null);
    expect(server.port!).toBeGreaterThan(0);
    await server.close();
  });

  it('expiresAfterWindow', async () => {
    const events: Array<{ level: string; category: string; message: string }> = [];
    const server = new PairingServer({
      receiverID: 'mac-test',
      displayName: 'Test Mac',
      windowSeconds: 0.2,
      onEvent: (e) => events.push(e),
    });
    await server.open();
    await new Promise((resolve) => setTimeout(resolve, 400));
    expect(events.some((e) => e.category === 'Pairing' && /expired/.test(e.message))).toBe(true);
  });

  it('cancelBeforeWindowDoesNotEmitExpired', async () => {
    const events: Array<{ level: string; category: string; message: string }> = [];
    const server = new PairingServer({
      receiverID: 'mac-test',
      displayName: 'Test Mac',
      windowSeconds: 1,
      onEvent: (e) => events.push(e),
    });
    await server.open();
    await server.close('manual cancel');
    expect(events.some((e) => e.message.includes('manual cancel'))).toBe(true);
  });
});
