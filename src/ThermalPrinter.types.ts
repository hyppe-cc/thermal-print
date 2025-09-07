import type { StyleProp, ViewStyle } from 'react-native';

export type OnLoadEventPayload = {
  url: string;
};


export type ChangeEventPayload = {
  value: string;
};

export type ConnectionStatus = 'connected' | 'disconnected' | 'connecting' | 'error';

export type BluetoothDevice = {
  address: string;
  name: string;
};

export type BluetoothConnectionEvent = {
  status: ConnectionStatus;
  deviceId?: string;
  deviceName?: string;
  error?: string;
};

export type BluetoothDeviceFoundEvent = {
  device: BluetoothDevice;
};

export type ThermalBleModuleEvents = {
  onConnectionChange: (params: BluetoothConnectionEvent) => void;
  onDeviceFound: (params: BluetoothDeviceFoundEvent) => void;
};

export type ThermalPrinterViewProps = {
  url: string;
  onLoad: (event: { nativeEvent: OnLoadEventPayload }) => void;
  style?: StyleProp<ViewStyle>;
};
