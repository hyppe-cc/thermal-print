import { requireNativeView } from 'expo';
import * as React from 'react';

import { ThermalPrinterViewProps } from './ThermalPrinter.types';

const NativeView: React.ComponentType<ThermalPrinterViewProps> =
  requireNativeView('ThermalPrinter');

export default function ThermalPrinterView(props: ThermalPrinterViewProps) {
  return <NativeView {...props} />;
}
