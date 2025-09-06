 ✅ Completed Features

  iOS Native Module (ThermalBleModule.swift):
  - isBluetoothEnabled() - Check if Bluetooth is powered on
  - scanDevices() - Scan for BLE devices with 30-second
  auto-timeout
  - stopScan() - Manually stop scanning and return found
  devices
  - connect(deviceId) - Connect to a specific device
  - disconnect() - Disconnect from current device
  - isConnected() - Check connection status
  - writeData(data) - Send byte array to connected printer
  - Event emitters:
    - onConnectionChange - Fires on connect/disconnect/error
    - onDeviceFound - Fires when devices are discovered
  during scan

  Printing Functionality (ThermalPrinter.ts):
  - printText(text) - Print text with automatic line feed
  - printLine() - Print empty line break
  - setBold(bool) - Enable/disable bold text
  - setAlignment(0|1|2) - Set text alignment (left/center/right)
  - init() - Initialize printer to default settings
  - cut() - Cut paper (if supported)
  - feed(lines) - Feed paper by specified lines

  TypeScript API (ThermalBleModule.ts):
  - Full TypeScript definitions for all methods
  - addConnectionListener() - Subscribe to connection events
  - Proper event types (BluetoothConnectionEvent)
  - Connection statuses: 'connected', 'disconnected',
  'connecting', 'error'

  Architecture:
  - Separated concerns: ThermalBLE for connections,
  ThermalPrinter for ESC/POS formatting
  - Used delegate pattern to handle CBCentralManagerDelegate
  and CBPeripheralDelegate without conflicting with Expo's
  Module class
  - Automatic service/characteristic discovery on connection
  - DispatchQueue for reliable 30-second scan timeout
  - Weak references to prevent retain cycles

  📝 Key Implementation Details

  1. Bluetooth Delegate Pattern: Created separate
  BluetoothDelegate class to handle CoreBluetooth callbacks
  2. Scan Timeout: Using DispatchQueue.main.asyncAfter
  instead of Timer for reliable 30-second timeout
  3. Device Discovery: Stores peripherals in dictionary,
  sends events during scan, returns array when complete
  4. Connection Management: Handles disconnecting from
  previous device before connecting to new one

  🔧 Usage Example

  import { ThermalBleModule, ThermalPrinter, 
           addConnectionListener } from 'thermal-printer';

  // Listen for connections
  const subscription = addConnectionListener((event) => {
    console.log('Status:', event.status);
  });

  // Scan for devices
  const devices = await ThermalBleModule.scanDevices();

  // Connect to device
  await ThermalBleModule.connect(devices[0].address);

  // Print to device
  await ThermalPrinter.printText("Hello World!");
  await ThermalPrinter.setBold(true);
  await ThermalPrinter.printText("Bold text");
  await ThermalPrinter.feed(2);

  // Clean up
  subscription.remove();

  📱 Ready for Testing

  The module is ready for device testing with full printing
  capability. Remember to add Bluetooth permissions to Info.plist:
  - NSBluetoothAlwaysUsageDescription
  - NSBluetoothPeripheralUsageDescription

  Complete workflow: Scan → Connect → Print with ESC/POS commands