import { NativeModule, requireNativeModule } from 'expo';

import { ThermalPrinterModuleEvents } from './ThermalPrinter.types';

declare class ThermalPrinterModule extends NativeModule<ThermalPrinterModuleEvents> {
  PI: number;
  hello(): string;
  setValueAsync(value: string): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ThermalPrinterModule>('ThermalPrinter');
