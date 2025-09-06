import ExpoModulesCore
import CoreBluetooth

public class ThermalPrinterModule: Module {
  // ESC/POS Commands
  private let ESC: UInt8 = 0x1B
  private let GS: UInt8 = 0x1D
  private let LF: UInt8 = 0x0A  // Line feed
  
  // Reference to connected peripheral and characteristic
  private var connectedPeripheral: CBPeripheral?
  private var writeCharacteristic: CBCharacteristic?
  
  public func definition() -> ModuleDefinition {
    
    Name("ThermalPrinter")

    AsyncFunction("printText") { (text: String, promise: Promise) in
      self.printTextToDevice(text, promise: promise)
    }
    
    AsyncFunction("printLine") { (promise: Promise) in
      // Print an empty line (just line feed)
      self.printTextToDevice("\n", promise: promise)
    }
    
    AsyncFunction("setPeripheral") { (peripheralId: String, promise: Promise) in
      // This will be called from ThermalBleModule when connected
      // For now, just resolve
      promise.resolve(nil)
    }
  }
  
  private func printTextToDevice(_ text: String, promise: Promise) {
    // For now, we'll need to get the peripheral from ThermalBleModule
    // This is a simplified version that just prepares the data
    
    var dataToSend = Data()
    
    // Convert text to data using UTF-8 encoding
    if let textData = text.data(using: .utf8) {
      dataToSend.append(textData)
    }
    
    // Add line feed at the end
    dataToSend.append(LF)
    
    // For testing, just log and resolve
    print("Would send to printer: \(text)")
    print("Data bytes: \(dataToSend.map { String(format: "%02X", $0) }.joined(separator: " "))")
    
    promise.resolve("Text sent: \(text)")
  }
}
