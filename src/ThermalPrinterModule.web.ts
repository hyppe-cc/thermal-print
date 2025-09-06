import { registerWebModule, NativeModule } from 'expo';

import { ThermalPrinterModuleEvents } from './ThermalPrinter.types';

class ThermalPrinterModule extends NativeModule<ThermalPrinterModuleEvents> {
  PI = Math.PI;
  async setValueAsync(value: string): Promise<void> {
    this.emit('onChange', { value });
  }
  hello() {
    return 'Hello world! 👋';
  }
}

export default registerWebModule(ThermalPrinterModule, 'ThermalPrinterModule');
