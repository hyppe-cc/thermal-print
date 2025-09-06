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
      
      // Convert UIImage directly to printer format (keep existing QR behavior)
      let imageData = self.convertQRImageToPrinterData(resizedImage, printerWidth: printerWidth)
      
      // Send image data to printer
      self.printPromise = promise
      self.sendImageDataToPrinter(imageData)
    }
    
    AsyncFunction("printImage") { (imageBase64: String, printerWidth: Int, promise: Promise) in
      guard self.connectedPeripheral != nil,
            self.writeCharacteristic != nil else {
        promise.reject("NOT_CONNECTED", "No device connected")
        return
      }
      
      // Decode base64 image
      guard let imageData = Data(base64Encoded: imageBase64),
            let originalImage = UIImage(data: imageData) else {
        promise.reject("INVALID_IMAGE", "Could not decode base64 image data")
        return
      }
      
      print("Original image: \(originalImage.size.width)x\(originalImage.size.height)")
      
      // Use same actual size as QR codes (which render at 3x due to retina)
      let targetImageWidth: Int
      if printerWidth <= 58 {
        targetImageWidth = 360  // Match actual QR code size for 58mm
      } else {
        targetImageWidth = 450  // Match actual QR code size for 80mm (150 * 3)
      }
      
      print("Printer width: \(printerWidth)mm, using fixed image width: \(targetImageWidth) pixels")
      
      // Scale image to fixed width while maintaining aspect ratio
      let processedImage = self.processImageForThermalPrinting(originalImage, 
                                                              targetWidth: targetImageWidth)
      
      // Convert to printer data with centering (same as QR code)
      let printerData = self.convertImageToPrinterDataCentered(processedImage, printerWidth: printerWidth)
      
      // Send image data to printer
      self.printPromise = promise
      self.sendImageDataToPrinter(printerData)
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
  
  // MARK: - Image Processing Helper Methods
  
  private func processImageForThermalPrinting(_ image: UIImage, targetWidth: Int) -> UIImage {
    guard let cgImage = image.cgImage else {
      return image
    }
    
    let originalWidth = CGFloat(cgImage.width)
    let originalHeight = CGFloat(cgImage.height)
    
    // Calculate scale factor to fit image to target width
    let scaleFactor = CGFloat(targetWidth) / originalWidth
    
    // Calculate new height maintaining aspect ratio
    let targetHeight = Int(originalHeight * scaleFactor)
    
    print("Scaling image from \(Int(originalWidth))x\(Int(originalHeight)) to \(targetWidth)x\(targetHeight)")
    print("Scale factor: \(scaleFactor)")
    
    // Create a Core Graphics context with exact pixel dimensions
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
    
    guard let context = CGContext(data: nil,
                                  width: targetWidth,
                                  height: targetHeight,
                                  bitsPerComponent: 8,
                                  bytesPerRow: targetWidth * 4,
                                  space: colorSpace,
                                  bitmapInfo: bitmapInfo.rawValue) else {
      return image
    }
    
    // Set high quality interpolation
    context.interpolationQuality = .high
    
    // Draw the scaled image
    context.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
    
    // Get the scaled CGImage
    guard let scaledCGImage = context.makeImage() else {
      return image
    }
    
    // Create UIImage with scale factor of 1.0 to ensure 1:1 pixel mapping
    let processedImage = UIImage(cgImage: scaledCGImage, scale: 1.0, orientation: image.imageOrientation)
    
    print("Target was: \(targetWidth)x\(targetHeight)")
    print("Actual CGImage size: \(scaledCGImage.width)x\(scaledCGImage.height)")
    print("UIImage size: \(processedImage.size.width)x\(processedImage.size.height), scale: \(processedImage.scale)")
    
    // Verify the image is the expected size
    if scaledCGImage.width != targetWidth {
      print("WARNING: Image width mismatch! Expected \(targetWidth), got \(scaledCGImage.width)")
    }
    
    return processedImage
  }
  
  private func convertImageToPrinterDataCentered(_ image: UIImage, printerWidth: Int) -> Data {
    // Use same approach as QR code - print at 360px width, let printer handle centering
    guard let cgImage = image.cgImage else {
      return Data()
    }
    
    let imageWidth = cgImage.width
    let imageHeight = cgImage.height
    
    print("Image for printing: \(imageWidth)x\(imageHeight) pixels")
    // No padding - print exactly like QR code does at 360px
    
    // Convert image to 1-bit bitmap
    let colorSpace = CGColorSpaceCreateDeviceGray()
    var pixelData = [UInt8](repeating: 0, count: imageWidth * imageHeight)
    
    let context = CGContext(data: &pixelData,
                           width: imageWidth,
                           height: imageHeight,
                           bitsPerComponent: 8,
                           bytesPerRow: imageWidth,
                           space: colorSpace,
                           bitmapInfo: CGImageAlphaInfo.none.rawValue)
    
    context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    
    var result = Data()
    
    // Use ESC/POS raster image format (GS v 0) for proper block printing
    result.append(contentsOf: [0x1D, 0x76, 0x30, 0x00]) // GS v 0 m
    
    // Calculate width in bytes - no padding, same as QR code
    let widthBytes = (imageWidth + 7) / 8
    print("Image width \(imageWidth) pixels = \(widthBytes) bytes")
    
    let xL = UInt8(widthBytes & 0xFF)
    let xH = UInt8((widthBytes >> 8) & 0xFF)
    let yL = UInt8(imageHeight & 0xFF)
    let yH = UInt8((imageHeight >> 8) & 0xFF)
    
    result.append(contentsOf: [xL, xH, yL, yH])
    
    // Process all lines without padding - exactly like QR code
    for y in 0..<imageHeight {
      var lineBytes = Data()
      var bitBuffer: UInt8 = 0
      var bitCount = 0
      
      // Process image pixels only
      for x in 0..<imageWidth {
        let pixelIndex = y * imageWidth + x
        let pixel = pixelData[pixelIndex]
        let bit: UInt8 = pixel < 128 ? 1 : 0 // 1 = black, 0 = white
        
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
    
    // Add spacing after image (same as QR code)
    result.append(0x0A)
    
    return result
  }
  
  private func convertImageToPrinterData(_ image: UIImage, printerWidth: Int) -> Data {
    guard let cgImage = image.cgImage else {
      return Data()
    }
    
    // Use actual CGImage dimensions (raw pixels, no scale factor)
    let imageWidth = cgImage.width
    let imageHeight = cgImage.height
    
    print("CGImage actual dimensions: \(imageWidth)x\(imageHeight)")
    print("UIImage size: \(image.size.width)x\(image.size.height), scale: \(image.scale)")
    
    // Convert image to 1-bit bitmap
    let colorSpace = CGColorSpaceCreateDeviceGray()
    var pixelData = [UInt8](repeating: 0, count: imageWidth * imageHeight)
    
    let context = CGContext(data: &pixelData,
                           width: imageWidth,
                           height: imageHeight,
                           bitsPerComponent: 8,
                           bytesPerRow: imageWidth,
                           space: colorSpace,
                           bitmapInfo: CGImageAlphaInfo.none.rawValue)
    
    context?.draw(cgImage, in: CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    
    print("Converting image to printer data: \(imageWidth)x\(imageHeight) pixels")
    
    var result = Data()
    
    // Since image is already scaled to printer width, no centering needed
    // Image width should match printer dots width after scaling
    
    // Use ESC/POS raster image format (GS v 0) for proper block printing
    result.append(contentsOf: [0x1D, 0x76, 0x30, 0x00]) // GS v 0 m
    
    // Calculate width in bytes
    let widthBytes = (imageWidth + 7) / 8
    print("Image width \(imageWidth) pixels = \(widthBytes) bytes")
    
    let xL = UInt8(widthBytes & 0xFF)
    let xH = UInt8((widthBytes >> 8) & 0xFF)
    let yL = UInt8(imageHeight & 0xFF)
    let yH = UInt8((imageHeight >> 8) & 0xFF)
    
    result.append(contentsOf: [xL, xH, yL, yH])
    
    // Process all lines
    for y in 0..<imageHeight {
      var lineBytes = Data()
      var bitBuffer: UInt8 = 0
      var bitCount = 0
      
      // Process image pixels
      for x in 0..<imageWidth {
        let pixelIndex = y * imageWidth + x
        let pixel = pixelData[pixelIndex]
        let bit: UInt8 = pixel < 128 ? 1 : 0 // 1 = black, 0 = white
        
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
    
    // Add spacing after image
    result.append(0x0A)
    
    return result
  }
  
  private func convertQRImageToPrinterData(_ qrImage: UIImage, printerWidth: Int) -> Data {
    // Use the unified image conversion method but without centering for QR codes
    // to maintain the existing behavior
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
    
    // Simple approach - no padding, just print QR code as-is (keep existing behavior)
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
