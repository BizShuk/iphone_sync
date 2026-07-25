// Setup renderer — wires the Setup DOM to the preload `window.iphoneSync` API.

import './global.js';

const api = window.iphoneSync;

const els = {
  launchAtLogin: document.getElementById('launch-at-login') as HTMLInputElement,
  statusPrimary: document.getElementById('status-primary') as HTMLDivElement,
  statusSecondary: document.getElementById('status-secondary') as HTMLDivElement,
  statusIcon: document.getElementById('status-icon') as HTMLDivElement,
  storageMode: document.getElementById('storage-mode') as HTMLSelectElement,
  chooseDestination: document.getElementById('choose-destination') as HTMLButtonElement,
  pairIPhone: document.getElementById('pair-iphone') as HTMLButtonElement,
  pairingCard: document.getElementById('pairing-card') as HTMLDivElement,
  pairingCode: document.getElementById('pairing-code') as HTMLDivElement,
  pairingMeta: document.getElementById('pairing-meta') as HTMLDivElement,
  errorBanner: document.getElementById('error-banner') as HTMLDivElement,
  statAdded: document.getElementById('stat-added') as HTMLDivElement,
  statExisting: document.getElementById('stat-existing') as HTMLDivElement,
  statNotLocal: document.getElementById('stat-notlocal') as HTMLDivElement,
  statFailed: document.getElementById('stat-failed') as HTMLDivElement,
  copyAll: document.getElementById('copy-all') as HTMLButtonElement,
  clearLog: document.getElementById('clear-log') as HTMLButtonElement,
  logMeta: document.getElementById('operation-log-meta') as HTMLParagraphElement,
  logList: document.getElementById('operation-log-list') as HTMLUListElement,
};

function renderSnapshot(snap: any): void {
  els.launchAtLogin.checked = snap.launchAtLogin;
  els.storageMode.value = snap.storageMode;
  els.statusPrimary.textContent = snap.pairedPeerDisplayName
    ? `iPhone ${snap.pairedPeerDisplayName}`
    : (snap.destinationPath ? 'Pair an iPhone' : 'Choose a destination');
  els.statusSecondary.textContent = snap.pairedPeerID ?? '';
  els.pairIPhone.disabled = !snap.destinationPath;

  if (snap.isPairing && snap.pairingCode) {
    els.pairingCard.classList.remove('hidden');
    els.pairingCode.textContent = snap.pairingCode;
    const expiresAt = snap.pairingExpiresAt ? new Date(snap.pairingExpiresAt) : null;
    if (expiresAt) {
      const remaining = Math.max(0, Math.floor((expiresAt.getTime() - Date.now()) / 1000));
      els.pairingMeta.textContent = `${Math.floor(remaining / 60)}:${String(remaining % 60).padStart(2, '0')} remaining`;
    }
  } else {
    els.pairingCard.classList.add('hidden');
  }

  if (snap.lastSummary) {
    els.statAdded.textContent = String(snap.lastSummary.added);
    els.statExisting.textContent = String(snap.lastSummary.existing);
    els.statNotLocal.textContent = String(snap.lastSummary.notLocal);
    els.statFailed.textContent = String(snap.lastSummary.failed);
  }

  els.logList.innerHTML = '';
  for (const entry of snap.operationLog) {
    const li = document.createElement('li');
    li.innerHTML = `
      <span class="operation-log-time">${new Date(entry.occurredAt).toLocaleTimeString()}</span>
      <span class="operation-log-body">
        <span class="category">${entry.category}</span>
        <span class="message">${entry.message}</span>
      </span>
      <span class="operation-log-level level-${entry.level}">${entry.level}</span>
    `;
    els.logList.appendChild(li);
  }
  els.logMeta.textContent = snap.operationLog.length === 0
    ? 'No operations recorded. Secrets and pairing codes are not recorded.'
    : `${snap.operationLog.length} recorded.`;

  els.copyAll.disabled = snap.operationLog.length === 0;
  els.clearLog.disabled = snap.operationLog.length === 0;
}

els.launchAtLogin.addEventListener('change', () => void api.setLaunchAtLogin(els.launchAtLogin.checked));
els.storageMode.addEventListener('change', () => void api.setStorageMode(els.storageMode.value as 'albumDate' | 'albumOnly' | 'flat'));
els.chooseDestination.addEventListener('click', () => void api.chooseDestination());
els.pairIPhone.addEventListener('click', () => void api.openPairing());
els.copyAll.addEventListener('click', () => void api.copyOperationLog());
els.clearLog.addEventListener('click', () => void api.clearOperationLog());

(async () => {
  const initial = await api.snapshot();
  renderSnapshot(initial);
  api.onSnapshot(renderSnapshot);
})();

export {};
