package expo.modules.thermalprinter

import android.Manifest
import android.annotation.SuppressLint
import android.bluetooth.*
import android.bluetooth.le.BluetoothLeScanner
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanResult
import android.content.Context
import android.content.pm.PackageManager
import android.content.Intent
import android.content.BroadcastReceiver
import android.content.IntentFilter
import java.io.IOException
import java.io.OutputStream
import java.util.UUID
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Color
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Base64
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.graphics.scale
import androidx.core.graphics.get // KTX import for getPixel
import androidx.core.graphics.set // KTX import for setPixel operator
import androidx.core.graphics.createBitmap // KTX import for createBitmap
import com.google.zxing.BarcodeFormat
import com.google.zxing.qrcode.QRCodeWriter
import expo.modules.kotlin.Promise
import expo.modules.kotlin.modules.Module
import expo.modules.kotlin.modules.ModuleDefinition
import expo.modules.interfaces.permissions.PermissionsResponse
import expo.modules.interfaces.permissions.PermissionsStatus
import kotlin.collections.HashMap

class ThermalBleModule : Module() {
  private var bluetoothManager: BluetoothManager? = null
  private var bluetoothAdapter: BluetoothAdapter? = null
  private var bluetoothLeScanner: BluetoothLeScanner? = null
  private var bluetoothGatt: BluetoothGatt? = null
  private var writeCharacteristic: BluetoothGattCharacteristic? = null
  
  private val foundDevices = HashMap<String, BluetoothDevice>()
  private var scanPromise: Promise? = null
  private var connectPromise: Promise? = null
  private var writePromise: Promise? = null
  private var isScanning = false
  private var isConnected = false
  private var connectedDeviceId: String? = null
  
  private val scanHandler = Handler(Looper.getMainLooper())
  private var scanTimeoutRunnable: Runnable? = null
  
  // For chunked data transmission
  private var dataChunks: List<ByteArray> = emptyList()
  private var currentChunkIndex = 0
  
  // For pairing support
  private var pairingReceiver: BroadcastReceiver? = null
  private var pairingPromise: Promise? = null
  private var defaultPin = "1234" // Default PIN for most thermal printers
  
  // For Classic Bluetooth
  private var bluetoothSocket: BluetoothSocket? = null
  private var socketOutputStream: OutputStream? = null
  private var isClassicBluetooth = false
  
  companion object {
    private const val TAG = "ThermalBleModule"
    private const val SCAN_TIMEOUT_MS = 30000L // 30 seconds
    private const val CONNECTION_TIMEOUT_MS = 15000L // 15 seconds
    private const val WRITE_CHUNK_SIZE = 100
    // Standard Serial Port Profile UUID for most thermal printers
    private val SPP_UUID: UUID = UUID.fromString("00001101-0000-1000-8000-00805F9B34FB")
  }

  override fun definition() = ModuleDefinition {
    Name("ThermalBle")
    
    Events("onConnectionChange", "onDeviceFound")
    
    OnCreate {
      appContext.reactContext?.let { context ->
        bluetoothManager = context.getSystemService(Context.BLUETOOTH_SERVICE) as? BluetoothManager
        bluetoothAdapter = bluetoothManager?.adapter
        bluetoothLeScanner = bluetoothAdapter?.bluetoothLeScanner
      }
    }
    
    OnDestroy {
      unregisterPairingReceiver()
    }
    
    AsyncFunction("isBluetoothEnabled") { promise: Promise ->
      promise.resolve(bluetoothAdapter?.isEnabled == true)
    }
    
    AsyncFunction("scanDevices") { promise: Promise ->
      // Check and request permissions first
      if (!hasBluetoothPermissions()) {
        requestBluetoothPermissions { granted ->
          if (granted) {
            startScanning(promise)
          } else {
            promise.reject("BLUETOOTH_PERMISSION_DENIED", "Bluetooth permissions not granted", null)
          }
        }
        return@AsyncFunction
      }
      
      startScanning(promise)
    }
    
    AsyncFunction("requestBluetoothPermissions") { promise: Promise ->
      requestBluetoothPermissions { granted ->
        promise.resolve(granted)
      }
    }
    
    AsyncFunction("getBluetoothState") { promise: Promise ->
      val state = mapOf(
        "isEnabled" to (bluetoothAdapter?.isEnabled == true),
        "hasPermissions" to hasBluetoothPermissions(),
        "supportsBLE" to (bluetoothLeScanner != null),
        "adapterState" to (bluetoothAdapter?.state ?: -1),
        "bondedDevicesCount" to try {
          bluetoothAdapter?.bondedDevices?.size ?: 0
        } catch (e: SecurityException) {
          0
        }
      )
      promise.resolve(state)
    }
    
    AsyncFunction("stopScan") { promise: Promise ->
      if (isScanning) {
        stopScanning()
      }
      promise.resolve(null)
    }
    
    AsyncFunction("connect") { deviceId: String, promise: Promise ->
      // Check permissions first
      if (!hasBluetoothPermissions()) {
        promise.reject("BLUETOOTH_PERMISSION_DENIED", "Bluetooth permissions not granted", null)
        return@AsyncFunction
      }
      
      stopScanning()
      
      // Check if already connected to this device
      if (isConnected && connectedDeviceId == deviceId) {
        Log.d(TAG, "Already connected to device: $deviceId")
        promise.resolve(null)
        return@AsyncFunction
      }
      
      // Disconnect from current device if connected to a different one
      if (isConnected) {
        Log.d(TAG, "Disconnecting from current device before connecting to new one")
        try {
          bluetoothGatt?.disconnect()
          bluetoothGatt?.close()
        } catch (e: SecurityException) {
          Log.e(TAG, "SecurityException during disconnect: ${e.message}")
        }
        bluetoothGatt = null
        writeCharacteristic = null
        isConnected = false
        connectedDeviceId = null
      }
      
      connectPromise = promise
      
      // Find device and connect
      val device = foundDevices[deviceId] ?: findDeviceByAddress(deviceId)
      
      if (device != null) {
        Log.d(TAG, "Device found in cache, connecting directly: ${getDeviceName(device)} (${device.address})")
        connectToDevice(device)
      } else {
        // Device not found, start scanning for it
        Log.d(TAG, "Device not found in cache, starting scan to find: $deviceId")
        targetDeviceAddress = deviceId
        
        try {
          val scanSettings = android.bluetooth.le.ScanSettings.Builder()
            .setScanMode(android.bluetooth.le.ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(android.bluetooth.le.ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setReportDelay(0)
            .build()
            
          bluetoothLeScanner?.startScan(emptyList(), scanSettings, connectScanCallback)
        } catch (e: SecurityException) {
          Log.e(TAG, "SecurityException starting scan for connect: ${e.message}")
          connectPromise?.reject("BLUETOOTH_PERMISSION_DENIED", "Missing Bluetooth permissions", e)
          connectPromise = null
          targetDeviceAddress = null
          return@AsyncFunction
        }
        
        // Timeout for finding device
        scanHandler.postDelayed({
          try {
            bluetoothLeScanner?.stopScan(connectScanCallback)
          } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException stopping scan for connect: ${e.message}")
          }
          if (connectPromise != null) {
            connectPromise?.reject("DEVICE_NOT_FOUND", "Device not found during connect scan", null)
            connectPromise = null
          }
          targetDeviceAddress = null
        }, 10000)
      }
    }
    
    AsyncFunction("disconnect") { promise: Promise ->
      try {
        if (isClassicBluetooth) {
          bluetoothSocket?.close()
          bluetoothSocket = null
          socketOutputStream = null
        } else {
          bluetoothGatt?.disconnect()
          bluetoothGatt?.close()
          bluetoothGatt = null
          writeCharacteristic = null
        }
      } catch (e: SecurityException) {
        Log.e(TAG, "SecurityException during disconnect: ${e.message}")
        promise.reject("BLUETOOTH_PERMISSION_DENIED", "Missing Bluetooth permissions for disconnect", e)
        return@AsyncFunction
      } catch (e: IOException) {
        Log.e(TAG, "IOException during Classic Bluetooth disconnect: ${e.message}")
      }
      
      isConnected = false
      connectedDeviceId = null
      isClassicBluetooth = false
      promise.resolve(null)
    }
    
    AsyncFunction("isConnected") { promise: Promise ->
      promise.resolve(isConnected)
    }
    
    AsyncFunction("getConnectionStatus") { promise: Promise ->
      val status = mapOf(
        "isConnected" to isConnected,
        "hasGattConnection" to (bluetoothGatt != null),
        "hasWriteCharacteristic" to (writeCharacteristic != null),
        "isReadyToWrite" to isReadyToWrite(),
        "connectedDeviceId" to connectedDeviceId
      )
      promise.resolve(status)
    }
    
    AsyncFunction("pairDevice") { deviceId: String, pin: String?, promise: Promise ->
      if (!hasBluetoothPermissions()) {
        promise.reject("BLUETOOTH_PERMISSION_DENIED", "Bluetooth permissions not granted", null)
        return@AsyncFunction
      }
      
      val device = foundDevices[deviceId] ?: findDeviceByAddress(deviceId)
      if (device == null) {
        promise.reject("DEVICE_NOT_FOUND", "Device not found", null)
        return@AsyncFunction
      }
      
      // Set the PIN to use
      defaultPin = pin ?: "1234"
      pairingPromise = promise
      
      // Register pairing receiver
      registerPairingReceiver()
      
      // Start pairing
      try {
        val paired = device.createBond()
        if (!paired) {
          promise.reject("PAIRING_FAILED", "Failed to initiate pairing", null)
          pairingPromise = null
          unregisterPairingReceiver()
        }
      } catch (e: SecurityException) {
        promise.reject("BLUETOOTH_PERMISSION_DENIED", "Missing Bluetooth permissions for pairing", e)
        pairingPromise = null
        unregisterPairingReceiver()
      }
    }
    
    AsyncFunction("isDevicePaired") { deviceId: String, promise: Promise ->
      try {
        val device = foundDevices[deviceId] ?: findDeviceByAddress(deviceId)
        if (device != null) {
          promise.resolve(device.bondState == BluetoothDevice.BOND_BONDED)
        } else {
          promise.resolve(false)
        }
      } catch (e: SecurityException) {
        promise.reject("BLUETOOTH_PERMISSION_DENIED", "Missing Bluetooth permissions", e)
      }
    }
    
    @SuppressLint("MissingPermission")
    AsyncFunction("writeData") { data: List<Int>, promise: Promise ->
      if (!isReadyToWrite()) {
        val errorMsg = when {
          !isConnected -> "No device connected"
          bluetoothGatt == null -> "GATT connection is null"
          writeCharacteristic == null -> "No write characteristic found"
          else -> "Device not ready for writing"
        }
        Log.e(TAG, "Write failed: $errorMsg")
        promise.reject("NOT_CONNECTED", errorMsg, null)
        return@AsyncFunction
      }
      
      writePromise = promise
      val byteArray = data.map { it.toByte() }.toByteArray()
      
      Log.d(TAG, "Writing data to printer (${if (isClassicBluetooth) "Classic" else "BLE"}): ${byteArray.joinToString(" ") { String.format("%02X", it) }}")
      
      if (isClassicBluetooth) {
        // Classic Bluetooth - write directly to socket
        Thread {
          try {
            socketOutputStream?.write(byteArray)
            socketOutputStream?.flush()
            
            scanHandler.post {
              writePromise?.resolve(null)
              writePromise = null
            }
            
          } catch (e: IOException) {
            Log.e(TAG, "IOException during Classic Bluetooth write: ${e.message}")
            scanHandler.post {
              writePromise?.reject("WRITE_ERROR", "Failed to write data: ${e.message}", e)
              writePromise = null
            }
          }
        }.start()
        
      } else {
        // BLE - write to characteristic
        try {
          if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            val result = bluetoothGatt?.writeCharacteristic(writeCharacteristic!!, byteArray, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
            if (result != BluetoothStatusCodes.SUCCESS) {
              writePromise?.reject("WRITE_ERROR", "Failed to write data with status: $result", null)
              writePromise = null
            }
          } else {
            @Suppress("DEPRECATION")
            writeCharacteristic?.value = byteArray
            @Suppress("DEPRECATION")
            val success = bluetoothGatt?.writeCharacteristic(writeCharacteristic) == true
            if (!success) {
              writePromise?.reject("WRITE_ERROR", "Failed to write data", null)
              writePromise = null
            }
          }
        } catch (e: SecurityException) {
          Log.e(TAG, "SecurityException during BLE writeData: ${e.message}")
          writePromise?.reject("BLUETOOTH_PERMISSION_DENIED", "Missing Bluetooth permissions for write", e)
          writePromise = null
        }
      }
    }
    
    AsyncFunction("printQRCode") { content: String, printerWidth: Int, promise: Promise ->
      if (!isReadyToWrite()) {
        val errorMsg = when {
          !isConnected -> "No device connected"
          bluetoothGatt == null -> "GATT connection is null"
          writeCharacteristic == null -> "No write characteristic found"
          else -> "Device not ready for printing"
        }
        Log.e(TAG, "Print QR failed: $errorMsg")
        promise.reject("NOT_CONNECTED", errorMsg, null)
        return@AsyncFunction
      }
      
      Log.d(TAG, "Generating QR Code: $content")
      
      try {
        // Determine QR code size based on printer width
        val qrSize = 360;
        
        Log.d(TAG, "Printer width: ${printerWidth}mm, QR size: ${qrSize}px")
        
        // Generate QR code bitmap
        val qrBitmap = generateQRCode(content, qrSize)
        
        // Convert to printer data
        val printerData = convertQRToPrinterData(qrBitmap)
        
        // Send data in chunks
        writePromise = promise
        sendDataInChunks(printerData)
        
      } catch (e: Exception) {
        promise.reject("ERROR_GENERATING_QRCODE", "Failed to generate QR code: ${e.message}", e)
      }
    }
    
    AsyncFunction("printImage") { imageBase64: String, printerWidth: Int, promise: Promise ->
      if (!isReadyToWrite()) {
        val errorMsg = when {
          !isConnected -> "No device connected"
          bluetoothGatt == null -> "GATT connection is null"
          writeCharacteristic == null -> "No write characteristic found"
          else -> "Device not ready for printing"
        }
        Log.e(TAG, "Print image failed: $errorMsg")
        promise.reject("NOT_CONNECTED", errorMsg, null)
        return@AsyncFunction
      }
      
      try {
        // Decode base64 image
        val imageBytes = Base64.decode(imageBase64, Base64.DEFAULT)
        val originalBitmap = BitmapFactory.decodeByteArray(imageBytes, 0, imageBytes.size)
          ?: throw Exception("Could not decode image")
        
        Log.d(TAG, "Original image: ${originalBitmap.width}x${originalBitmap.height}")
        
        // Determine target width (matching iOS behavior)
        val targetWidth = if (printerWidth <= 58) 360 else 450
        
        Log.d(TAG, "Printer width: ${printerWidth}mm, using fixed image width: $targetWidth pixels")
        
        // Scale image
        val scaledBitmap = scaleImageForPrinting(originalBitmap, targetWidth)
        
        // Convert to printer data
        val printerData = convertImageToPrinterData(scaledBitmap)
        
        // Send data in chunks
        writePromise = promise
        sendDataInChunks(printerData)
        
      } catch (e: Exception) {
        promise.reject("INVALID_IMAGE", "Failed to process image: ${e.message}", e)
      }
    }
  }
  
  private fun isReadyToWrite(): Boolean {
    return if (isClassicBluetooth) {
      isConnected && bluetoothSocket != null && socketOutputStream != null
    } else {
      isConnected && bluetoothGatt != null && writeCharacteristic != null
    }
  }
  
  @SuppressLint("MissingPermission")
  private fun registerPairingReceiver() {
    if (pairingReceiver == null) {
      pairingReceiver = object : BroadcastReceiver() {
        override fun onReceive(context: Context?, intent: Intent?) {
          when (intent?.action) {
            BluetoothDevice.ACTION_PAIRING_REQUEST -> {
              val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
              } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
              }
              
              val pairingVariant = intent.getIntExtra(BluetoothDevice.EXTRA_PAIRING_VARIANT, BluetoothDevice.ERROR)
              
              Log.d(TAG, "Pairing request from ${device?.address}, variant: $pairingVariant")
              
              when (pairingVariant) {
                BluetoothDevice.PAIRING_VARIANT_PIN -> {
                  // Set the PIN
                  val pinBytes = defaultPin.toByteArray()
                  device?.setPin(pinBytes)
                  abortBroadcast() // Prevent system dialog
                }
                BluetoothDevice.PAIRING_VARIANT_PASSKEY_CONFIRMATION -> {
                  // Auto-confirm pairing
                  device?.setPairingConfirmation(true)
                  abortBroadcast() // Prevent system dialog
                }
              }
            }
            
            BluetoothDevice.ACTION_BOND_STATE_CHANGED -> {
              val device = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE, BluetoothDevice::class.java)
              } else {
                @Suppress("DEPRECATION")
                intent.getParcelableExtra(BluetoothDevice.EXTRA_DEVICE)
              }
              
              val bondState = intent.getIntExtra(BluetoothDevice.EXTRA_BOND_STATE, BluetoothDevice.ERROR)
              val prevBondState = intent.getIntExtra(BluetoothDevice.EXTRA_PREVIOUS_BOND_STATE, BluetoothDevice.ERROR)
              
              Log.d(TAG, "Bond state changed: $prevBondState -> $bondState for ${device?.address}")
              
              when (bondState) {
                BluetoothDevice.BOND_BONDED -> {
                  Log.d(TAG, "Device paired successfully")
                  pairingPromise?.resolve(true)
                  pairingPromise = null
                  unregisterPairingReceiver()
                }
                BluetoothDevice.BOND_NONE -> {
                  if (prevBondState == BluetoothDevice.BOND_BONDING) {
                    Log.e(TAG, "Pairing failed")
                    pairingPromise?.reject("PAIRING_FAILED", "Pairing was rejected or failed", null)
                    pairingPromise = null
                    unregisterPairingReceiver()
                  }
                }
              }
            }
          }
        }
      }
      
      appContext.reactContext?.let { context ->
        val filter = IntentFilter().apply {
          addAction(BluetoothDevice.ACTION_PAIRING_REQUEST)
          addAction(BluetoothDevice.ACTION_BOND_STATE_CHANGED)
          priority = IntentFilter.SYSTEM_HIGH_PRIORITY
        }
        context.registerReceiver(pairingReceiver, filter)
      }
    }
  }
  
  private fun unregisterPairingReceiver() {
    pairingReceiver?.let { receiver ->
      appContext.reactContext?.unregisterReceiver(receiver)
      pairingReceiver = null
    }
  }
  
  private fun hasBluetoothPermissions(): Boolean {
    val context = appContext.reactContext ?: return false
    
    return if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      // Android 12+
      ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_SCAN) == PackageManager.PERMISSION_GRANTED &&
      ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_CONNECT) == PackageManager.PERMISSION_GRANTED
    } else {
      // Android 11 and below
      ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH) == PackageManager.PERMISSION_GRANTED &&
      ContextCompat.checkSelfPermission(context, Manifest.permission.BLUETOOTH_ADMIN) == PackageManager.PERMISSION_GRANTED &&
      ContextCompat.checkSelfPermission(context, Manifest.permission.ACCESS_FINE_LOCATION) == PackageManager.PERMISSION_GRANTED
    }
  }
  
  private fun requestBluetoothPermissions(callback: (Boolean) -> Unit) {
    val permissions = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
      // Android 12+
      arrayOf(
        Manifest.permission.BLUETOOTH_SCAN,
        Manifest.permission.BLUETOOTH_CONNECT
      )
    } else {
      // Android 11 and below
      arrayOf(
        Manifest.permission.BLUETOOTH,
        Manifest.permission.BLUETOOTH_ADMIN,
        Manifest.permission.ACCESS_FINE_LOCATION
      )
    }
    
    appContext.permissions?.askForPermissions(
      { permissionsResult: Map<String, PermissionsResponse> ->
        val allGranted = permissionsResult.values.all { it.status == PermissionsStatus.GRANTED }
        callback(allGranted)
      },
      *permissions
    ) ?: callback(false)
  }
  
  private fun startScanning(promise: Promise) {
    if (bluetoothAdapter?.isEnabled != true) {
      promise.reject("BLUETOOTH_INVALID_STATE", "Bluetooth is not powered on", null)
      return
    }
    
    if (isScanning) {
      stopScanning()
    }
    
    scanPromise = promise
    foundDevices.clear()
    isScanning = true
    
    // Add currently connected device to found devices if exists
    connectedDeviceId?.let { id ->
      bluetoothGatt?.device?.let { device ->
        foundDevices[id] = device
        sendEvent("onDeviceFound", mapOf(
          "device" to mapOf(
            "address" to device.address,
            "name" to getDeviceName(device)
          )
        ))
      }
    }
    
    // Also check bonded devices immediately at scan start
    try {
      bluetoothAdapter?.bondedDevices?.forEach { bondedDevice ->
        // Only add devices that might be printers (have device class or name indicating printer)
        val deviceName = getDeviceName(bondedDevice).lowercase()
        if (deviceName.contains("printer") || deviceName.contains("pos") || 
            deviceName.contains("thermal") || deviceName.contains("receipt")) {
          
          if (!foundDevices.containsKey(bondedDevice.address)) {
            foundDevices[bondedDevice.address] = bondedDevice
            Log.d(TAG, "Found bonded printer device: ${deviceName} (${bondedDevice.address})")
            
            // Send onDeviceFound event immediately
            sendEvent("onDeviceFound", mapOf(
              "device" to mapOf(
                "address" to bondedDevice.address,
                "name" to getDeviceName(bondedDevice)
              )
            ))
          }
        }
      }
    } catch (e: SecurityException) {
      Log.e(TAG, "SecurityException accessing bonded devices: ${e.message}")
    } catch (e: Exception) {
      Log.e(TAG, "Exception accessing bonded devices: ${e.message}")
    }
    
    // Start scanning with more aggressive settings
    try {
      val scanSettings = android.bluetooth.le.ScanSettings.Builder()
        .setScanMode(android.bluetooth.le.ScanSettings.SCAN_MODE_LOW_LATENCY) // More aggressive scanning
        .setCallbackType(android.bluetooth.le.ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
        .setMatchMode(android.bluetooth.le.ScanSettings.MATCH_MODE_AGGRESSIVE)
        .setNumOfMatches(android.bluetooth.le.ScanSettings.MATCH_NUM_MAX_ADVERTISEMENT)
        .setReportDelay(0) // Report immediately
        .build()
      
      Log.d(TAG, "Starting BLE scan with aggressive settings...")
      bluetoothLeScanner?.startScan(emptyList(), scanSettings, scanCallback)
      
      // Set timeout
      scanTimeoutRunnable = Runnable {
        if (isScanning) {
          Log.d(TAG, "Scan timeout after 30 seconds - stopping scan")
          stopScanning()
        }
      }
      scanHandler.postDelayed(scanTimeoutRunnable!!, SCAN_TIMEOUT_MS)
    } catch (e: SecurityException) {
      Log.e(TAG, "SecurityException during scan: ${e.message}")
      promise.reject("BLUETOOTH_PERMISSION_DENIED", "Missing Bluetooth permissions", e)
      isScanning = false
    } catch (e: Exception) {
      Log.e(TAG, "Exception during scan: ${e.message}")
      promise.reject("SCAN_ERROR", "Failed to start scan: ${e.message}", e)
      isScanning = false
    }
  }
  
  @SuppressLint("MissingPermission")
  private fun getDeviceName(device: BluetoothDevice): String {
    return try {
      device.name ?: ""
    } catch (_: SecurityException) {
      ""
    }
  }
  
  @SuppressLint("MissingPermission")
  private fun findDeviceByAddress(address: String): BluetoothDevice? {
    return try {
      bluetoothAdapter?.getRemoteDevice(address)
    } catch (_: Exception) {
      null
    }
  }
  
  @SuppressLint("MissingPermission")
  private fun connectToDevice(device: BluetoothDevice) {
    Log.d(TAG, "Attempting to connect to device: ${getDeviceName(device)} (${device.address})")
    
    // Check device type - most thermal printers are Classic Bluetooth
    val deviceClass = device.bluetoothClass
    val isLikelyPrinter = deviceClass?.deviceClass == BluetoothClass.Device.PERIPHERAL_NON_KEYBOARD_NON_POINTING ||
                         getDeviceName(device).lowercase().contains("printer")
    
    if (isLikelyPrinter) {
      Log.d(TAG, "Device appears to be a printer, trying Classic Bluetooth first")
      connectViaClassicBluetooth(device)
    } else {
      Log.d(TAG, "Trying BLE connection first")
      connectViaBLE(device)
    }
  }
  
  @SuppressLint("MissingPermission")
  private fun connectViaClassicBluetooth(device: BluetoothDevice) {
    Thread {
      try {
        Log.d(TAG, "Creating Classic Bluetooth socket connection")
        
        // Close any existing connections
        bluetoothSocket?.close()
        bluetoothGatt?.close()
        bluetoothSocket = null
        bluetoothGatt = null
        socketOutputStream = null
        
        // Create socket connection
        bluetoothSocket = device.createRfcommSocketToServiceRecord(SPP_UUID)
        
        // Cancel discovery to improve connection reliability
        bluetoothAdapter?.cancelDiscovery()
        
        // Connect to the socket
        bluetoothSocket?.connect()
        socketOutputStream = bluetoothSocket?.outputStream
        
        // Connection successful
        isConnected = true
        isClassicBluetooth = true
        connectedDeviceId = device.address
        targetDeviceAddress = null
        
        Log.d(TAG, "Classic Bluetooth connection successful")
        
        // Resolve promise on main thread
        scanHandler.post {
          connectPromise?.resolve(null)
          connectPromise = null
          
          sendEvent("onConnectionChange", mapOf(
            "status" to "connected",
            "deviceId" to device.address,
            "deviceName" to getDeviceName(device)
          ))
        }
        
      } catch (e: IOException) {
        Log.e(TAG, "Classic Bluetooth connection failed: ${e.message}")
        
        // Try BLE as fallback
        scanHandler.post {
          Log.d(TAG, "Falling back to BLE connection")
          connectViaBLE(device)
        }
        
      } catch (e: SecurityException) {
        Log.e(TAG, "SecurityException during Classic Bluetooth connect: ${e.message}")
        scanHandler.post {
          connectPromise?.reject("BLUETOOTH_PERMISSION_DENIED", "Missing Bluetooth permissions for connect", e)
          connectPromise = null
          targetDeviceAddress = null
        }
      }
    }.start()
    
    // Set connection timeout
    scanHandler.postDelayed({
      if (connectPromise != null && !isConnected) {
        Log.e(TAG, "Classic Bluetooth connection timeout")
        bluetoothSocket?.close()
        bluetoothSocket = null
        socketOutputStream = null
        
        // Try BLE as fallback
        Log.d(TAG, "Timeout - falling back to BLE connection")
        connectViaBLE(device)
      }
    }, CONNECTION_TIMEOUT_MS)
  }
  
  @SuppressLint("MissingPermission")
  private fun connectViaBLE(device: BluetoothDevice) {
    appContext.reactContext?.let { context ->
      try {
        // Clear any previous connections
        bluetoothGatt?.close()
        bluetoothSocket?.close()
        bluetoothGatt = null
        bluetoothSocket = null
        socketOutputStream = null
        isClassicBluetooth = false
        
        // Connect to the device via BLE
        bluetoothGatt = device.connectGatt(context, false, gattCallback)
        
        if (bluetoothGatt == null) {
          Log.e(TAG, "Failed to create GATT connection")
          connectPromise?.reject("CONNECTION_FAILED", "Failed to create GATT connection", null)
          connectPromise = null
          targetDeviceAddress = null
        } else {
          Log.d(TAG, "BLE GATT connection initiated")
          // Connection result will be handled in gattCallback.onConnectionStateChange
          
          // Set connection timeout for BLE
          scanHandler.postDelayed({
            if (connectPromise != null && !isConnected) {
              Log.e(TAG, "BLE connection timeout after ${CONNECTION_TIMEOUT_MS}ms")
              connectPromise?.reject("CONNECTION_TIMEOUT", "Both Classic and BLE connections timed out", null)
              connectPromise = null
              targetDeviceAddress = null
              
              // Close the GATT connection
              bluetoothGatt?.disconnect()
              bluetoothGatt?.close()
              bluetoothGatt = null
            }
          }, CONNECTION_TIMEOUT_MS)
        }
      } catch (e: SecurityException) {
        Log.e(TAG, "SecurityException during BLE connect: ${e.message}")
        connectPromise?.reject("BLUETOOTH_PERMISSION_DENIED", "Missing Bluetooth permissions for connect", e)
        connectPromise = null
        targetDeviceAddress = null
      } catch (e: Exception) {
        Log.e(TAG, "Exception during BLE connect: ${e.message}")
        connectPromise?.reject("CONNECTION_FAILED", "Failed to connect: ${e.message}", e)
        connectPromise = null
        targetDeviceAddress = null
      }
    } ?: run {
      Log.e(TAG, "React context is null, cannot connect")
      connectPromise?.reject("CONTEXT_ERROR", "React context is null", null)
      connectPromise = null
      targetDeviceAddress = null
    }
  }
  
  private fun stopScanning() {
    try {
      bluetoothLeScanner?.stopScan(scanCallback)
    } catch (e: SecurityException) {
      Log.e(TAG, "SecurityException stopping scan: ${e.message}")
    } catch (e: Exception) {
      Log.e(TAG, "Exception stopping scan: ${e.message}")
    }
    
    isScanning = false
    scanTimeoutRunnable?.let { scanHandler.removeCallbacks(it) }
    scanTimeoutRunnable = null
    
    
    // Return found devices
    val devices = foundDevices.map { (_, device) ->
      mapOf(
        "address" to device.address,
        "name" to getDeviceName(device)
      )
    }
    
    Log.d(TAG, "Scan completed. Found ${devices.size} devices: ${devices.map { it["name"] }}")
    
    scanPromise?.resolve(devices)
    scanPromise = null
  }
  
  private fun sendDataInChunks(data: ByteArray) {
    if (isClassicBluetooth) {
      // For Classic Bluetooth, send all data at once (no chunking needed)
      writePromise?.let { promise ->
        Thread {
          try {
            socketOutputStream?.write(data)
            socketOutputStream?.flush()
            
            scanHandler.post {
              promise.resolve(null)
              writePromise = null
            }
            
          } catch (e: IOException) {
            Log.e(TAG, "IOException during Classic Bluetooth chunk write: ${e.message}")
            scanHandler.post {
              promise.reject("WRITE_ERROR", "Failed to write data chunks: ${e.message}", e)
              writePromise = null
            }
          }
        }.start()
      }
    } else {
      // For BLE, use chunking
      dataChunks = data.toList().chunked(WRITE_CHUNK_SIZE).map { it.toByteArray() }
      currentChunkIndex = 0
      
      Log.d(TAG, "Sending BLE data: ${data.size} bytes in ${dataChunks.size} chunks")
      sendNextChunk()
    }
  }
  
  @SuppressLint("MissingPermission")
  private fun sendNextChunk() {
    if (currentChunkIndex >= dataChunks.size) {
      // All chunks sent
      Log.d(TAG, "Data transmission completed successfully")
      writePromise?.resolve(null)
      writePromise = null
      dataChunks = emptyList()
      currentChunkIndex = 0
      return
    }
    
    val chunk = dataChunks[currentChunkIndex]
    Log.d(TAG, "Sending chunk ${currentChunkIndex + 1}/${dataChunks.size}: ${chunk.size} bytes")
    
    try {
      // Modern approach for setting value and writing characteristic if API level allows
      if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
        val result = bluetoothGatt?.writeCharacteristic(writeCharacteristic!!, chunk, BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT)
         if (result != BluetoothStatusCodes.SUCCESS) {
            writePromise?.reject("WRITE_ERROR", "Failed to write chunk with status: $result", null)
            writePromise = null
            dataChunks = emptyList()
            currentChunkIndex = 0
          }
      } else {
        @Suppress("DEPRECATION")
        writeCharacteristic?.value = chunk
        @Suppress("DEPRECATION")
        val success = bluetoothGatt?.writeCharacteristic(writeCharacteristic) == true
        if (!success) {
          writePromise?.reject("WRITE_ERROR", "Failed to write chunk", null)
          writePromise = null
          dataChunks = emptyList()
          currentChunkIndex = 0
        }
      }
    } catch (e: SecurityException) {
      Log.e(TAG, "SecurityException during sendNextChunk: ${e.message}")
      writePromise?.reject("BLUETOOTH_PERMISSION_DENIED", "Missing Bluetooth permissions for write", e)
      writePromise = null
      dataChunks = emptyList()
      currentChunkIndex = 0
    }
  }
  
  private fun generateQRCode(content: String, size: Int): Bitmap {
    val writer = QRCodeWriter()
    val bitMatrix = writer.encode(content, BarcodeFormat.QR_CODE, size, size)
    val width = bitMatrix.width
    val height = bitMatrix.height
    val bitmap = createBitmap(width, height, Bitmap.Config.RGB_565)
    
    for (x in 0 until width) {
      for (y in 0 until height) {
        bitmap[x, y] = if (bitMatrix[x, y]) Color.BLACK else Color.WHITE // Using KTX operator overloading
      }
    }
    
    return bitmap
  }
  
  private fun scaleImageForPrinting(bitmap: Bitmap, targetWidth: Int): Bitmap {
    val scaleFactor = targetWidth.toFloat() / bitmap.width
    val targetHeight = (bitmap.height * scaleFactor).toInt()
    
    Log.d(TAG, "Scaling image from ${bitmap.width}x${bitmap.height} to ${targetWidth}x${targetHeight}")
    
    return bitmap.scale(targetWidth, targetHeight, true)
  }
  
  private fun convertQRToPrinterData(bitmap: Bitmap): ByteArray {
    return convertBitmapToPrinterData(bitmap)
  }
  
  private fun convertImageToPrinterData(bitmap: Bitmap): ByteArray {
    return convertBitmapToPrinterData(bitmap)
  }
  
  private fun convertBitmapToPrinterData(bitmap: Bitmap): ByteArray {
    val width = bitmap.width
    val height = bitmap.height
    
    Log.d(TAG, "Converting bitmap to printer data: ${width}x${height} pixels")
    
    val result = mutableListOf<Byte>()
    
    // ESC/POS raster image format (GS v 0)
    result.add(0x1D.toByte()) // GS
    result.add(0x76.toByte()) // v
    result.add(0x30.toByte()) // 0
    result.add(0x00.toByte()) // m
    
    // Calculate width in bytes
    val widthBytes = (width + 7) / 8
    
    Log.d(TAG, "Image width $width pixels = $widthBytes bytes")
    
    // Add width and height parameters
    result.add((widthBytes and 0xFF).toByte())        // xL
    result.add(((widthBytes shr 8) and 0xFF).toByte()) // xH
    result.add((height and 0xFF).toByte())             // yL
    result.add(((height shr 8) and 0xFF).toByte())     // yH
    
    // Process each line
    for (y in 0 until height) {
      var bitBuffer = 0
      var bitCount = 0
      
      for (x in 0 until width) {
        val pixel = bitmap[x, y] // Using KTX extension
        val gray = (Color.red(pixel) + Color.green(pixel) + Color.blue(pixel)) / 3
        val bit = if (gray < 128) 1 else 0 // 1 = black, 0 = white
        
        bitBuffer = (bitBuffer shl 1) or bit
        bitCount++
        
        if (bitCount == 8) {
          result.add(bitBuffer.toByte())
          bitBuffer = 0
          bitCount = 0
        }
      }
      
      // Complete the last byte if needed
      if (bitCount > 0) {
        bitBuffer = bitBuffer shl (8 - bitCount)
        result.add(bitBuffer.toByte())
      }
    }
    
    // Add line feed after image
    result.add(0x0A.toByte())
    
    return result.toByteArray()
  }
  
  // Scan callback for device discovery
  private val scanCallback = object : ScanCallback() {
    override fun onScanResult(callbackType: Int, result: ScanResult?) { // Added nullable ScanResult
      super.onScanResult(callbackType, result)
      Log.d(TAG, "onScanResult called. CallbackType: $callbackType, Result RSSI: ${result?.rssi}, Device: ${result?.device?.address ?: "null"}")
      result?.device?.let { device ->
        val deviceAddress = device.address
        // Check if device already found to prevent duplicate events
        if (!foundDevices.containsKey(deviceAddress)) {
          Log.d(TAG, "New device discovered by onScanResult: ${getDeviceName(device)} (${deviceAddress})")
          foundDevices[deviceAddress] = device
          sendEvent("onDeviceFound", mapOf(
            "device" to mapOf(
              "address" to deviceAddress,
              "name" to getDeviceName(device)
            )
          ))
        } else {
          // Optional: Log if a known device is seen again, can be noisy
          // Log.d(TAG, "Known device seen again by onScanResult: ${getDeviceName(device)} (${deviceAddress})")
        }
      } ?: run {
          Log.d(TAG, "onScanResult received null ScanResult or null Device object.")
      }
    }

    override fun onBatchScanResults(results: MutableList<ScanResult>?) {
      super.onBatchScanResults(results)
      Log.d(TAG, "onBatchScanResults called with ${results?.size ?: 0} results.")
      results?.forEach { result ->
        result.device?.let { device ->
          val deviceAddress = device.address
          if (!foundDevices.containsKey(deviceAddress)) {
            Log.d(TAG, "New device discovered by onBatchScanResults: ${getDeviceName(device)} (${deviceAddress})")
            foundDevices[deviceAddress] = device
            sendEvent("onDeviceFound", mapOf(
              "device" to mapOf(
                "address" to deviceAddress,
                "name" to getDeviceName(device)
              )
            ))
          }
        }
      }
    }

    override fun onScanFailed(errorCode: Int) {
      super.onScanFailed(errorCode)
      Log.e(TAG, "Scan failed with error code: $errorCode. See android.bluetooth.le.ScanCallback constants for details (e.g., SCAN_FAILED_ALREADY_STARTED).")
      scanPromise?.reject("SCAN_FAILED", "Bluetooth scan failed with error code: $errorCode", null)
      scanPromise = null // Clear the promise to prevent multiple resolutions/rejections
      isScanning = false // Ensure scanning state is updated
    }
  }
  
  // Scan callback for connecting to specific device
  private var targetDeviceAddress: String? = null
  
  private val connectScanCallback = object : ScanCallback() {
    override fun onScanResult(callbackType: Int, result: ScanResult) {
      val device = result.device
      
      if (device.address == targetDeviceAddress) {
        Log.d(TAG, "Found target device for connection: ${device.address}")
        try {
          bluetoothLeScanner?.stopScan(this)
        } catch (e: SecurityException) {
          Log.e(TAG, "SecurityException stopping scan for connect: ${e.message}")
        }
        connectToDevice(device)
      }
    }
    
    override fun onScanFailed(errorCode: Int) {
      Log.e(TAG, "Connect scan failed with error: $errorCode")
      connectPromise?.reject("SCAN_FAILED", "Failed to scan for device during connect", null)
      connectPromise = null
      targetDeviceAddress = null
    }
  }
  
  // GATT callback for BLE operations
  private val gattCallback = object : BluetoothGattCallback() {
    override fun onConnectionStateChange(gatt: BluetoothGatt, status: Int, newState: Int) {
      when (newState) {
        BluetoothProfile.STATE_CONNECTED -> {
          if (status == BluetoothGatt.GATT_SUCCESS) {
            Log.d(TAG, "Connected to GATT server successfully")
            isConnected = true
            connectedDeviceId = gatt.device.address
            targetDeviceAddress = null // Clear target address
            
            // Discover services
            try {
              val serviceDiscoveryStarted = gatt.discoverServices()
              if (!serviceDiscoveryStarted) {
                Log.e(TAG, "Failed to start service discovery")
                connectPromise?.reject("SERVICE_DISCOVERY_FAILED", "Failed to start service discovery", null)
                connectPromise = null
                return
              }
              Log.d(TAG, "Service discovery started")
              
              // Don't resolve connectPromise here - wait for onServicesDiscovered
              
            } catch (e: SecurityException) {
              Log.e(TAG, "SecurityException discovering services: ${e.message}")
              connectPromise?.reject("BLUETOOTH_PERMISSION_DENIED", "Missing Bluetooth permissions", e)
              connectPromise = null
              return
            }
            
            sendEvent("onConnectionChange", mapOf(
              "status" to "connected",
              "deviceId" to gatt.device.address,
              "deviceName" to getDeviceName(gatt.device)
            ))
          } else {
            Log.e(TAG, "Connection failed with status: $status")
            connectPromise?.reject("CONNECTION_FAILED", "GATT connection failed with status: $status", null)
            connectPromise = null
            targetDeviceAddress = null
          }
        }
        
        BluetoothProfile.STATE_CONNECTING -> {
          Log.d(TAG, "Connecting to GATT server...")
          sendEvent("onConnectionChange", mapOf(
            "status" to "connecting",
            "deviceId" to gatt.device.address,
            "deviceName" to getDeviceName(gatt.device)
          ))
        }
        
        BluetoothProfile.STATE_DISCONNECTED -> {
          Log.d(TAG, "Disconnected from GATT server (status: $status)")
          val wasConnected = isConnected
          
          isConnected = false
          connectedDeviceId = null
          writeCharacteristic = null
          targetDeviceAddress = null
          
          // If we were trying to connect and got disconnected, it's a connection failure
          if (!wasConnected && connectPromise != null) {
            connectPromise?.reject("CONNECTION_FAILED", "Device disconnected during connection attempt (status: $status)", null)
            connectPromise = null
          }
          
          sendEvent("onConnectionChange", mapOf(
            "status" to "disconnected",
            "deviceId" to gatt.device.address,
            "error" to if (status != BluetoothGatt.GATT_SUCCESS) "Disconnection status: $status" else null
          ))
          
          try {
            gatt.close()
          } catch (e: SecurityException) {
            Log.e(TAG, "SecurityException during gatt.close(): ${e.message}")
          }
          bluetoothGatt = null
        }
      }
    }
    
    override fun onServicesDiscovered(gatt: BluetoothGatt, status: Int) {
      if (status == BluetoothGatt.GATT_SUCCESS) {
        Log.d(TAG, "Services discovered successfully")
        
        var foundWriteCharacteristic = false
        
        // Look for writable characteristics
        for (service in gatt.services) {
          Log.d(TAG, "Discovered service: ${service.uuid}")
          
          for (characteristic in service.characteristics) {
            val properties = characteristic.properties
            Log.d(TAG, "Discovered characteristic: ${characteristic.uuid} with properties: $properties")
            
            // Check for write properties
            if (properties and BluetoothGattCharacteristic.PROPERTY_WRITE != 0 ||
                properties and BluetoothGattCharacteristic.PROPERTY_WRITE_NO_RESPONSE != 0) {
              writeCharacteristic = characteristic
              foundWriteCharacteristic = true
              Log.d(TAG, "Found write characteristic: ${characteristic.uuid}")
              break
            }
          }
          if (foundWriteCharacteristic) break
        }
        
        if (foundWriteCharacteristic) {
          Log.d(TAG, "Connection completed successfully with write characteristic")
          connectPromise?.resolve(null)
        } else {
          Log.w(TAG, "No write characteristic found, but connection completed")
          connectPromise?.resolve(null) // Still resolve since device is connected
        }
        connectPromise = null
        
      } else {
        Log.e(TAG, "Service discovery failed with status: $status")
        connectPromise?.reject("SERVICE_DISCOVERY_FAILED", "Service discovery failed with status: $status", null)
        connectPromise = null
        
        // Disconnect since service discovery failed
        try {
          gatt.disconnect()
        } catch (e: SecurityException) {
          Log.e(TAG, "SecurityException during disconnect after service discovery failure: ${e.message}")
        }
      }
    }
    
    override fun onCharacteristicWrite(
      gatt: BluetoothGatt,
      characteristic: BluetoothGattCharacteristic,
      status: Int
    ) {
      if (status == BluetoothGatt.GATT_SUCCESS) {
        Log.d(TAG, "Write completed successfully")
        
        // Check if we're sending chunks
        if (dataChunks.isNotEmpty() && currentChunkIndex < dataChunks.size - 1) {
          currentChunkIndex++
          sendNextChunk()
        } else {
          // Single write or last chunk completed
          writePromise?.resolve(null)
          writePromise = null
          
          if (dataChunks.isNotEmpty()) {
            dataChunks = emptyList()
            currentChunkIndex = 0
          }
        }
      } else {
        Log.e(TAG, "Write failed with status: $status")
        writePromise?.reject("WRITE_ERROR", "Write failed with status: $status", null)
        writePromise = null
        dataChunks = emptyList()
        currentChunkIndex = 0
      }
    }
  }
}
