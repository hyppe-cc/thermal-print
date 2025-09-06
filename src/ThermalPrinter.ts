import { ThermalBleModule } from './ThermalBleModule';

export class ThermalPrinter {
  // ESC/POS Commands
  private static readonly ESC = 0x1B;
  private static readonly GS = 0x1D;
  private static readonly LF = 0x0A; // Line feed

  /**
   * Print text to the thermal printer
   * @param text The text to print
   */
  static async printText(text: string): Promise<void> {
    const data: number[] = [];
    
    // Convert text to UTF-8 bytes
    const textBytes = new TextEncoder().encode(text);
    data.push(...Array.from(textBytes));
    
    // Add line feed
    data.push(this.LF);
    
    await ThermalBleModule.writeData(data);
  }

  /**
   * Print a line break
   */
  static async printLine(): Promise<void> {
    await ThermalBleModule.writeData([this.LF]);
  }

  /**
   * Initialize printer (reset to default settings)
   */
  static async init(): Promise<void> {
    await ThermalBleModule.writeData([this.ESC, 0x40]);
  }

  /**
   * Set text alignment
   * @param alignment 0=left, 1=center, 2=right
   */
  static async setAlignment(alignment: 0 | 1 | 2): Promise<void> {
    await ThermalBleModule.writeData([this.ESC, 0x61, alignment]);
  }

  /**
   * Set text bold
   * @param bold true for bold, false for normal
   */
  static async setBold(bold: boolean): Promise<void> {
    await ThermalBleModule.writeData([this.ESC, 0x45, bold ? 1 : 0]);
  }

  /**
   * Cut paper (if supported)
   */
  static async cut(): Promise<void> {
    await ThermalBleModule.writeData([this.GS, 0x56, 0x00]);
  }

  /**
   * Feed paper
   * @param lines Number of lines to feed
   */
  static async feed(lines: number = 1): Promise<void> {
    const data = Array(lines).fill(this.LF);
    await ThermalBleModule.writeData(data);
  }
}