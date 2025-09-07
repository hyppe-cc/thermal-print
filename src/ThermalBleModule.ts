import { NativeModule, requireNativeModule } from "expo";
import { EventSubscription } from "expo-modules-core";

import {
  ThermalBleModuleEvents,
  BluetoothConnectionEvent,
  BluetoothDeviceFoundEvent,
  BluetoothDevice,
} from "./ThermalPrinter.types";

declare class ThermalBleNativeModule extends NativeModule<ThermalBleModuleEvents> {
  isBluetoothEnabled(): Promise<boolean>;
  enableBluetooth(): Promise<boolean>;
  disableBluetooth(): Promise<boolean>;
  scanDevices(): Promise<BluetoothDevice[]>;
  stopScan(): Promise<void>;
  connect(deviceId: string): Promise<void>;
  disconnect(): Promise<void>;
  isConnected(): Promise<boolean>;
  writeData(data: number[]): Promise<void>;
  printQRCode(content: string, printerWidth: number): Promise<void>;
  printImage(imageBase64: string, printerWidth: number): Promise<void>;
}

export const ThermalBleModule =
  requireNativeModule<ThermalBleNativeModule>("ThermalBle");

export function addConnectionListener(
  listener: (event: BluetoothConnectionEvent) => void
): EventSubscription {
  return ThermalBleModule.addListener("onConnectionChange", listener);
}

export function addDeviceFoundListener(
  listener: (event: BluetoothDeviceFoundEvent) => void
): EventSubscription {
  return ThermalBleModule.addListener("onDeviceFound", listener);
}
