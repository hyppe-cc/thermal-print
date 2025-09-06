import { NativeModule, requireNativeModule } from "expo";
import { EventSubscription } from "expo-modules-core";

import {
  ThermalBleModuleEvents,
  BluetoothConnectionEvent,
} from "./ThermalPrinter.types";

declare class ThermalBleNativeModule extends NativeModule<ThermalBleModuleEvents> {
  isBluetoothEnabled(): Promise<boolean>;
  enableBluetooth(): Promise<boolean>;
  disableBluetooth(): Promise<boolean>;
  scanDevices(): Promise<any[]>;
  stopScan(): Promise<void>;
  connect(deviceId: string): Promise<void>;
  disconnect(): Promise<void>;
  isConnected(): Promise<boolean>;
  writeData(data: number[]): Promise<void>;
}

export const ThermalBleModule =
  requireNativeModule<ThermalBleNativeModule>("ThermalBle");

export function addConnectionListener(
  listener: (event: BluetoothConnectionEvent) => void
): EventSubscription {
  return ThermalBleModule.addListener("onConnectionChange", listener);
}
