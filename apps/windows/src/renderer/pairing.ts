// Pairing renderer — updates the six-digit code and the countdown every second.
// `window.iphoneSync` ambient declaration is contributed by `./global.d.ts`,
// which is auto-included via the root tsconfig `include: ["src/**/*"]` glob.

const api = window.iphoneSync;

const codeEl = document.getElementById('pairing-code') as HTMLDivElement;
const metaEl = document.getElementById('pairing-meta') as HTMLDivElement;

let expiresAt: Date | null = null;
function tick(): void {
  if (!expiresAt) return;
  const remaining = Math.max(0, Math.floor((expiresAt.getTime() - Date.now()) / 1000));
  metaEl.textContent = `${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, '0')} remaining`;
  if (remaining === 0) {
    codeEl.textContent = 'expired';
  }
}

api.onPairingUpdate(({ code, expiresAt: raw }) => {
  codeEl.textContent = code;
  expiresAt = new Date(raw);
  tick();
});

setInterval(tick, 1000);

export {};
