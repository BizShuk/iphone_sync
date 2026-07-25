import { describe, expect, it } from 'vitest';
import { OperationLogBuffer } from '../src/logging';

describe('OperationLogBuffer', () => {
  it('operationLogBufferKeepsNewestEntriesAndClears', () => {
    const buf = new OperationLogBuffer(2);
    buf.record({ level: 'info', category: 'A', message: 'm1' });
    buf.record({ level: 'info', category: 'A', message: 'm2' });
    buf.record({ level: 'info', category: 'A', message: 'm3' });
    expect(buf.all.length).toBe(2);
    expect(buf.all[0]?.message).toBe('m3');
    expect(buf.all[1]?.message).toBe('m2');
    buf.clear();
    expect(buf.all.length).toBe(0);
  });
});
