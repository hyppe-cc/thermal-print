import { ThermalBleModule } from './ThermalBleModule';

export class ThermalPrinter {
  // ESC/POS Commands
  private static readonly ESC = 0x1B;
  private static readonly GS = 0x1D;
  private static readonly LF = 0x0A; // Line feed

  // Printer width settings (characters per line)
  private static printerWidths = {
    58: 32,  // 58mm printer = ~32 characters
    80: 48,  // 80mm printer = ~48 characters
  };

  private static currentWidth = 32; // Default to 58mm

  /**
   * Set printer width based on paper size
   * @param mm Paper width in millimeters (58 or 80)
   */
  static setPrinterWidth(mm: 58 | 80): void {
    this.currentWidth = this.printerWidths[mm];
  }

  /**
   * Get current printer width in characters
   */
  static getPrinterWidth(): number {
    return this.currentWidth;
  }

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

  /**
   * Print two-column layout: left text and right text
   * Fills space between left and right text to push right text to the edge
   * @param leftText Text for left side
   * @param rightText Text for right side
   */
  static async printTwoColumns(leftText: string, rightText: string): Promise<void> {
    const maxWidth = this.currentWidth;
    const totalTextLength = leftText.length + rightText.length;
    
    if (totalTextLength >= maxWidth) {
      // If combined text is too long, truncate left text
      const availableLeftWidth = maxWidth - rightText.length - 1;
      const truncatedLeft = leftText.substring(0, Math.max(0, availableLeftWidth));
      await this.printText(truncatedLeft + ' ' + rightText);
    } else {
      // Fill space between left and right text
      const spacesNeeded = maxWidth - totalTextLength;
      const spaces = ' '.repeat(spacesNeeded);
      await this.printText(leftText + spaces + rightText);
    }
  }

  /**
   * Print QR code (automatically sized and centered based on current printer width)
   * @param content Text content to encode in QR code
   */
  static async printQRCode(content: string): Promise<void> {
    // Get current printer width in mm (58 or 80)
    const printerWidthMm = Object.entries(this.printerWidths)
      .find(([, chars]) => chars === this.currentWidth)?.[0] || '58';
    
    await ThermalBleModule.printQRCode(content, parseInt(printerWidthMm));
  }

}