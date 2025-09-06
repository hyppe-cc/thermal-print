import ExpoModulesCore
import CoreBluetooth

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
    } else {
      print("Write completed successfully")
      self.printPromise?.resolve(nil)
    }
    self.printPromise = nil
  }
}
