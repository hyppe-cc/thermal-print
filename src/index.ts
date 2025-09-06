// Reexport the native module. On web, it will be resolved to ThermalPrinterModule.web.ts
// and on native platforms to ThermalPrinterModule.ts
export { default } from './ThermalPrinterModule';
export { default as ThermalPrinterView } from './ThermalPrinterView';
export * from  './ThermalPrinter.types';
