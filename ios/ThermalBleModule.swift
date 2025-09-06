import ExpoModulesCore
import CoreBluetooth
import EFQRCode

// Extension to chunk Data into smaller pieces
extension Data {
  func chunked(into size: Int) -> [Data] {
    return stride(from: 0, to: count, by: size).map {
      Data(self[$0..<Swift.min($0 + size, count)])
    }
  }
}

// Delegate class to handle CBCentralManagerDelegate and CBPeripheralDelegate
class BluetoothDelegate: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
  weak var module: ThermalBleModule?
  
  // MARK: - CBCentralManagerDelegate
  
  func centralManagerDidUpdateState(_ central: CBCentralManager) {
    module?.handleBluetoothStateUpdate(central)
  }
  
  func centralManager(_ central: CBCentralManager,
                     didDiscover peripheral: CBPeripheral,
                     advertisementData: [String : Any],
                     rssi RSSI: NSNumber) {
    module?.handlePeripheralDiscovered(peripheral, advertisementData: advertisementData)
  }
  
  func centralManager(_ central: CBCentralManager,
                     didConnect peripheral: CBPeripheral) {
    module?.handlePeripheralConnected(peripheral)
  }
  
  func centralManager(_ central: CBCentralManager,
                     didFailToConnect peripheral: CBPeripheral,
                     error: Error?) {
    module?.handlePeripheralFailedToConnect(peripheral, error: error)
  }
  
  func centralManager(_ central: CBCentralManager,
                     didDisconnectPeripheral peripheral: CBPeripheral,
                     error: Error?) {
    module?.handlePeripheralDisconnected(peripheral, error: error)
  }
  
  // MARK: - CBPeripheralDelegate
  
  func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
    module?.handleServicesDiscovered(peripheral, error: error)
  }
  
  func peripheral(_ peripheral: CBPeripheral, 
                 didDiscoverCharacteristicsFor service: CBService, 
                 error: Error?) {
    module?.handleCharacteristicsDiscovered(peripheral, service: service, error: error)
  }
  
  func peripheral(_ peripheral: CBPeripheral, 
                 didWriteValueFor characteristic: CBCharacteristic, 
                 error: Error?) {
    module?.handleWriteComplete(peripheral, characteristic: characteristic, error: error)
  }
}

public class ThermalBleModule: Module {
  private var centralManager: CBCentralManager?
  private var bluetoothDelegate: BluetoothDelegate?
  private var bluetoothStatePromise: Promise?
  private var scanPromise: Promise?
  private var foundDevices: [String: CBPeripheral] = [:]
  private var scanTimer: Timer?
  private var connectedPeripheral: CBPeripheral?
  private var connectPromise: Promise?
  private var waitingToConnect: String?
  private var writeCharacteristic: CBCharacteristic?
  private var printPromise: Promise?
  
  public func definition() -> ModuleDefinition {
    Name("ThermalBle")
    
    Events("onConnectionChange", "onDeviceFound")
    
    OnCreate {
      self.bluetoothDelegate = BluetoothDelegate()
      self.bluetoothDelegate?.module = self
      self.centralManager = CBCentralManager(delegate: self.bluetoothDelegate!, queue: nil)
    }
    
    AsyncFunction("isBluetoothEnabled") { (promise: Promise) in
      if let manager = self.centralManager {
        promise.resolve(manager.state == .poweredOn)
      } else {
        self.centralManager = CBCentralManager(delegate: self.bluetoothDelegate!, queue: nil)
        self.bluetoothStatePromise = promise
      }
    }
    
    AsyncFunction("scanDevices") { (promise: Promise) in
      guard let manager = self.centralManager, manager.state == .poweredOn else {
        promise.reject("BLUETOOTH_INVALID_STATE", "Bluetooth is not powered on")
        return
      }
      
      if manager.isScanning {
        manager.stopScan()
      }
      
      self.scanPromise = promise
      self.foundDevices.removeAll()
      
      // If there's a connected peripheral, add it to found devices
      if let connected = self.connectedPeripheral {
        let deviceInfo: [String: Any] = [
          "address": connected.identifier.uuidString,
          "name": connected.name ?? ""
        ]
        self.foundDevices[connected.identifier.uuidString] = connected
        
        self.sendEvent("onDeviceFound", ["device": deviceInfo])
      }
      
      // Start scanning
      manager.scanForPeripherals(withServices: nil, options: [
        CBCentralManagerScanOptionAllowDuplicatesKey: false
      ])
      
      // Set timeout for 30 seconds
      self.scanTimer?.invalidate()
      
      // Use DispatchQueue for more reliable timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 30.0) { [weak self] in
        guard let self = self else { return }
        if self.scanPromise != nil {
          print("Scan timeout after 30 seconds - stopping scan")
          self.stopScanning()
        }
      }
    }
    
    AsyncFunction("connect") { (deviceId: String, promise: Promise) in
      self.stopScanning()
      
      // Check if already connected to this device
      if let connected = self.connectedPeripheral,
         connected.identifier.uuidString == deviceId {
        promise.resolve(nil)
        return
      }
      
      // If connected to a different device, disconnect first
      if let connected = self.connectedPeripheral {
        self.centralManager?.cancelPeripheralConnection(connected)
      }
      
      self.connectPromise = promise
      self.waitingToConnect = deviceId
      
      // Try to find the peripheral in our discovered devices
      if let peripheral = self.foundDevices[deviceId] {
        self.centralManager?.connect(peripheral, options: nil)
      } else {
        // If not found, scan for it
        guard let manager = self.centralManager, manager.state == .poweredOn else {
          promise.reject("BLUETOOTH_INVALID_STATE", "Bluetooth is not powered on")
          return
        }
        
        manager.scanForPeripherals(withServices: nil, options: [
          CBCentralManagerScanOptionAllowDuplicatesKey: false
        ])
      }
    }
    
    AsyncFunction("disconnect") { (promise: Promise) in
      if let connected = self.connectedPeripheral {
        self.centralManager?.cancelPeripheralConnection(connected)
        promise.resolve(nil)
      } else {
        promise.resolve(nil)
      }
    }
    
    AsyncFunction("isConnected") { (promise: Promise) in
      promise.resolve(self.connectedPeripheral != nil)
    }
    
    AsyncFunction("stopScan") { (promise: Promise) in
      if self.centralManager?.isScanning == true {
        self.stopScanning()
      }
      promise.resolve(nil)
    }
    
    AsyncFunction("writeData") { (data: [UInt8], promise: Promise) in
      guard let peripheral = self.connectedPeripheral,
            let characteristic = self.writeCharacteristic else {
        promise.reject("NOT_CONNECTED", "No device connected or no write characteristic found")
        return
      }
      
      self.printPromise = promise
      let dataToWrite = Data(data)
      print("Writing data to printer: \(dataToWrite.map { String(format: "%02X", $0) }.joined(separator: " "))")
      peripheral.writeValue(dataToWrite, for: characteristic, type: .withResponse)
    }
    
    AsyncFunction("printQRCode") { (content: String, printerWidth: Int, promise: Promise) in
      guard self.connectedPeripheral != nil,
            self.writeCharacteristic != nil else {
        promise.reject("NOT_CONNECTED", "No device connected")
        return
      }
      
      print("Generating QR Code: \(content)")
      
      // Generate QR code with better size for image printing
      let finalSize: Int
      if printerWidth <= 58 {
        finalSize = 120  // Bigger for better scanning
      } else {
        finalSize = 150  // Bigger for 80mm printer
      }
      
      print("Printer width: \(printerWidth)mm, QR size: \(finalSize)px")
      
      // Generate QR code using EFQRCode (pure Swift)
      guard let qrCGImage = EFQRCode.generate(for: content) else {
        promise.reject("ERROR_GENERATING_QRCODE", "Failed to generate QR code image")
        return
      }
      
      // Convert to UIImage
      let baseQRImage = UIImage(cgImage: qrCGImage)
      
      // Ensure QR code is perfectly square
      let squareSize = finalSize
      let renderer = UIGraphicsImageRenderer(size: CGSize(width: squareSize, height: squareSize))
      let resizedImage = renderer.image { context in
        // Disable interpolation for crisp pixels
        context.cgContext.interpolationQuality = .none
        // Force square aspect ratio
        baseQRImage.draw(in: CGRect(x: 0, y: 0, width: squareSize, height: squareSize))
      }
      
      // Convert UIImage directly to printer format
      let imageData = self.convertQRImageToPrinterData(resizedImage, printerWidth: printerWidth)
      
      // Send image data to printer
      self.printPromise = promise
      self.sendImageDataToPrinter(imageData)
    }
  }
  
  private func stopScanning() {
    self.centralManager?.stopScan()
    self.scanTimer?.invalidate()
    self.scanTimer = nil
    
    // Return found devices as array
    let devices = self.foundDevices.map { (key, peripheral) in
      return [
        "address": peripheral.identifier.uuidString,
        "name": peripheral.name ?? ""
      ]
    }
    
    self.scanPromise?.resolve(devices)
    self.scanPromise = nil
  }
  
  // MARK: - QR Code Helper Methods
  
  private func convertQRImageToPrinterData(_ qrImage: UIImage, printerWidth: Int) -> Data {
    guard let cgImage = qrImage.cgImage else {
      return Data()
    }
    
    let qrWidth = Int(cgImage.width)
    let qrHeight = Int(cgImage.height)
    
    // Convert image to 1-bit bitmap
    let colorSpace = CGColorSpaceCreateDeviceGray()
    var pixelData = [UInt8](repeating: 0, count: qrWidth * qrHeight)
    
    let context = CGContext(data: &pixelData,
                           width: qrWidth,
                           height: qrHeight,
                           bitsPerComponent: 8,
                           bytesPerRow: qrWidth,
                           space: colorSpace,
                           bitmapInfo: CGImageAlphaInfo.none.rawValue)
    
    context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: qrWidth, height: qrHeight))
    
    print("QR Debug: \(qrWidth)x\(qrHeight)")
    
    var result = Data()
    
    // Simple approach - no padding, just print QR code as-is
    print("QR data will be \(qrWidth) pixels wide")
    
    // Use ESC/POS raster image format (GS v 0) for proper block printing
    result.append(contentsOf: [0x1D, 0x76, 0x30, 0x00]) // GS v 0 m
    
    // Calculate width in bytes for just the QR code
    let widthBytes = (qrWidth + 7) / 8
    
    let xL = UInt8(widthBytes & 0xFF)
    let xH = UInt8((widthBytes >> 8) & 0xFF)
    let yL = UInt8(qrHeight & 0xFF)
    let yH = UInt8((qrHeight >> 8) & 0xFF)
    
    result.append(contentsOf: [xL, xH, yL, yH])
    
    // Process all lines as one block - no padding
    for y in 0..<qrHeight {
      var lineBytes = Data()
      var bitBuffer: UInt8 = 0
      var bitCount = 0
      
      // Add QR pixels only
      for x in 0..<qrWidth {
        let pixelIndex = y * qrWidth + x
        let pixel = pixelData[pixelIndex]
        let bit: UInt8 = pixel < 128 ? 1 : 0 // 1 = black
        
        bitBuffer = (bitBuffer << 1) | bit
        bitCount += 1
        
        if bitCount == 8 {
          lineBytes.append(bitBuffer)
          bitBuffer = 0
          bitCount = 0
        }
      }
      
      // Complete the last byte if needed
      if bitCount > 0 {
        bitBuffer <<= (8 - bitCount)
        lineBytes.append(bitBuffer)
      }
      
      result.append(lineBytes)
    }
    
    // Add spacing after QR code
    result.append(0x0A)
    
    return result
  }
  
  private func convertImageToPrinterData(_ image: UIImage, width: Int, height: Int, leftPadding: Int) -> Data {
    // Convert UIImage to grayscale bitmap
    let grayscaleData = imageToGrayscale(image, width: width, height: height)
    
    // Apply threshold to convert to black/white
    let binaryData = applyThreshold(grayscaleData, width: width, height: height)
    
    // Convert to ESC/POS image format
    let escPosData = convertToESCPOSFormat(binaryData, width: width, height: height, leftPadding: leftPadding)
    
    return escPosData
  }
  
  private func imageToGrayscale(_ image: UIImage, width: Int, height: Int) -> [UInt8] {
    let colorSpace = CGColorSpaceCreateDeviceGray()
    var grayscaleData = [UInt8](repeating: 0, count: width * height)
    
    let context = CGContext(data: &grayscaleData,
                           width: width,
                           height: height,
                           bitsPerComponent: 8,
                           bytesPerRow: width,
                           space: colorSpace,
                           bitmapInfo: CGImageAlphaInfo.none.rawValue)
    
    context?.draw(image.cgImage!, in: CGRect(x: 0, y: 0, width: width, height: height))
    
    return grayscaleData
  }
  
  private func applyThreshold(_ grayscaleData: [UInt8], width: Int, height: Int) -> [UInt8] {
    let threshold: UInt8 = 128
    return grayscaleData.map { $0 > threshold ? 0 : 1 } // 0 = white, 1 = black
  }
  
  private func convertToESCPOSFormat(_ binaryData: [UInt8], width: Int, height: Int, leftPadding: Int) -> Data {
    var result = Data()
    
    // Add left padding if specified
    if leftPadding > 0 {
      // ESC a n (set left margin)
      result.append(contentsOf: [0x1B, 0x61, UInt8(leftPadding)])
    }
    
    // ESC/POS image command: GS v 0
    result.append(contentsOf: [0x1D, 0x76, 0x30, 0x00]) // GS v 0 m
    
    // Width and height in bytes
    let widthBytes = (width + 7) / 8 // Round up to nearest byte
    let xL = UInt8(widthBytes & 0xFF)
    let xH = UInt8((widthBytes >> 8) & 0xFF)
    let yL = UInt8(height & 0xFF)
    let yH = UInt8((height >> 8) & 0xFF)
    
    result.append(contentsOf: [xL, xH, yL, yH])
    
    // Convert binary data to bytes
    for y in 0..<height {
      var lineData = Data()
      for x in stride(from: 0, to: width, by: 8) {
        var byte: UInt8 = 0
        for bit in 0..<8 {
          if x + bit < width {
            let pixelIndex = y * width + x + bit
            if binaryData[pixelIndex] == 1 {
              byte |= (1 << (7 - bit))
            }
          }
        }
        lineData.append(byte)
      }
      result.append(lineData)
    }
    
    // Add line feed after image
    result.append(0x0A)
    
    return result
  }
  
  private func sendImageDataToPrinter(_ imageData: Data) {
    guard let peripheral = connectedPeripheral,
          let characteristic = writeCharacteristic else {
      printPromise?.reject("NOT_CONNECTED", "No device connected")
      printPromise = nil
      return
    }
    
    // Split into smaller chunks for more reliable transmission
    let chunkSize = 100 // Smaller chunks for QR text data
    let chunks = imageData.chunked(into: chunkSize)
    
    print("Sending QR data: \(imageData.count) bytes in \(chunks.count) chunks")
    sendImageChunks(chunks, to: peripheral, characteristic: characteristic, index: 0)
  }
  
  private var currentChunkIndex = 0
  private var currentChunks: [Data] = []
  
  private func sendImageChunks(_ chunks: [Data], to peripheral: CBPeripheral, characteristic: CBCharacteristic, index: Int) {
    guard index < chunks.count else {
      // All chunks sent successfully
      print("QR code transmission completed successfully")
      printPromise?.resolve(nil)
      printPromise = nil
      currentChunks = []
      currentChunkIndex = 0
      return
    }
    
    // Store chunks for callback continuation
    currentChunks = chunks
    currentChunkIndex = index
    
    let chunk = chunks[index]
    print("Sending chunk \(index + 1)/\(chunks.count): \(chunk.count) bytes")
    peripheral.writeValue(chunk, for: characteristic, type: .withResponse)
    
    // The next chunk will be sent from handleWriteComplete callback
  }
  
  // MARK: - Bluetooth Delegate Handlers
  
  func handleBluetoothStateUpdate(_ central: CBCentralManager) {
    if let promise = self.bluetoothStatePromise {
      promise.resolve(central.state == .poweredOn)
      self.bluetoothStatePromise = nil
    }
  }
  
  func handlePeripheralDiscovered(_ peripheral: CBPeripheral,
                                  advertisementData: [String : Any]) {
    // Store discovered peripheral
    self.foundDevices[peripheral.identifier.uuidString] = peripheral
    
    let deviceInfo: [String: Any] = [
      "address": peripheral.identifier.uuidString,
      "name": peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
    ]
    
    // Send event for each discovered device
    self.sendEvent("onDeviceFound", ["device": deviceInfo])
    
    // If this is the device we're waiting to connect to, connect now
    if let waitingId = self.waitingToConnect,
       peripheral.identifier.uuidString == waitingId {
      self.centralManager?.stopScan()
      self.centralManager?.connect(peripheral, options: nil)
    }
  }
  
  func handlePeripheralConnected(_ peripheral: CBPeripheral) {
    self.connectedPeripheral = peripheral
    self.waitingToConnect = nil
    
    // Set the delegate and discover services
    peripheral.delegate = self.bluetoothDelegate
    peripheral.discoverServices(nil)
    
    // Resolve the connect promise
    self.connectPromise?.resolve(nil)
    self.connectPromise = nil
    
    // Send connection event
    self.sendEvent("onConnectionChange", [
      "status": "connected",
      "deviceId": peripheral.identifier.uuidString,
      "deviceName": peripheral.name ?? ""
    ])
  }
  
  func handlePeripheralFailedToConnect(_ peripheral: CBPeripheral,
                                       error: Error?) {
    self.waitingToConnect = nil
    
    // Reject the connect promise
    self.connectPromise?.reject("CONNECTION_FAILED", 
                                error?.localizedDescription ?? "Failed to connect to device")
    self.connectPromise = nil
    
    // Send connection event
    self.sendEvent("onConnectionChange", [
      "status": "error",
      "deviceId": peripheral.identifier.uuidString,
      "error": error?.localizedDescription ?? "Connection failed"
    ])
  }
  
  func handlePeripheralDisconnected(_ peripheral: CBPeripheral,
                                    error: Error?) {
    if peripheral == self.connectedPeripheral {
      self.connectedPeripheral = nil
      self.writeCharacteristic = nil
      
      // Send disconnection event
      self.sendEvent("onConnectionChange", [
        "status": "disconnected",
        "deviceId": peripheral.identifier.uuidString,
        "error": error?.localizedDescription
      ])
    }
  }
  
  func handleServicesDiscovered(_ peripheral: CBPeripheral, error: Error?) {
    if let error = error {
      print("Error discovering services: \(error)")
      return
    }
    
    // Look for services with write characteristics
    guard let services = peripheral.services else { return }
    
    for service in services {
      print("Discovered service: \(service.uuid)")
      peripheral.discoverCharacteristics(nil, for: service)
    }
  }
  
  func handleCharacteristicsDiscovered(_ peripheral: CBPeripheral, service: CBService, error: Error?) {
    if let error = error {
      print("Error discovering characteristics: \(error)")
      return
    }
    
    guard let characteristics = service.characteristics else { return }
    
    for characteristic in characteristics {
      print("Discovered characteristic: \(characteristic.uuid) with properties: \(characteristic.properties)")
      
      // Look for writable characteristics
      if characteristic.properties.contains(.write) || characteristic.properties.contains(.writeWithoutResponse) {
        self.writeCharacteristic = characteristic
        print("Found write characteristic: \(characteristic.uuid)")
        break
      }
    }
  }
  
  func handleWriteComplete(_ peripheral: CBPeripheral, characteristic: CBCharacteristic, error: Error?) {
    if let error = error {
      print("Write error: \(error)")
      self.printPromise?.reject("WRITE_ERROR", error.localizedDescription)
      self.printPromise = nil
      currentChunks = []
      currentChunkIndex = 0
    } else {
      print("Write completed successfully")
      
      // Check if we're in the middle of sending QR chunks
      if !currentChunks.isEmpty && currentChunkIndex < currentChunks.count - 1 {
        // Continue with next chunk
        let nextIndex = currentChunkIndex + 1
        sendImageChunks(currentChunks, to: peripheral, characteristic: characteristic, index: nextIndex)
      } else {
        // Either regular text write completed OR QR chunks finished
        // Always resolve the promise and clear state
        self.printPromise?.resolve(nil)
        self.printPromise = nil
        
        // Clear chunk state if it exists
        if !currentChunks.isEmpty {
          currentChunks = []
          currentChunkIndex = 0
        }
      }
    }
  }
}
