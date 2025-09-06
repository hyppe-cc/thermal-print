import { NativeModule, requireNativeModule } from "expo";

import { ThermalPrinterModuleEvents } from "./ThermalPrinter.types";

declare class ThermalPrinterModule extends NativeModule<ThermalPrinterModuleEvents> {
  printText(text: string): Promise<string>;
  printLine(): Promise<string>;
  setPeripheral(peripheralId: string): Promise<void>;
}

// This call loads the native module object from the JSI.
export default requireNativeModule<ThermalPrinterModule>("ThermalPrinter");
