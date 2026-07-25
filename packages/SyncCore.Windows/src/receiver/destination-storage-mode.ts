// DestinationStorageMode — enum mirroring `DestinationStorageMode.swift`.

export const DestinationStorageMode = {
  albumDate: 'albumDate',
  albumOnly: 'albumOnly',
  flat: 'flat',
} as const;

export type DestinationStorageModeType = typeof DestinationStorageMode[keyof typeof DestinationStorageMode];

export function isDestinationStorageMode(value: string): value is DestinationStorageModeType {
  return value === DestinationStorageMode.albumDate
    || value === DestinationStorageMode.albumOnly
    || value === DestinationStorageMode.flat;
}
