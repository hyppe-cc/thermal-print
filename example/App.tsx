import { useEffect, useState } from "react";
import {
  Button,
  SafeAreaView,
  ScrollView,
  Text,
  TouchableOpacity,
  View,
} from "react-native";

import {
  ThermalBleModule,
  ThermalPrinter,
  addConnectionListener,
} from "thermal-printer";
import { base } from "./bas";
import { pika } from "./pika";

export default function App() {
  const [devices, setDevices] = useState<any[]>([]);
  const [scanning, setScanning] = useState(false);
  const [scanStartTime, setScanStartTime] = useState<number>(0);

  useEffect(() => {
    const subscription = addConnectionListener((event) => {
      console.log("Connection event:", event);
    });

    return () => subscription.remove();
  }, []);

  const startScan = async () => {
    try {
      setScanning(true);
      setDevices([]);
      setScanStartTime(Date.now());
      console.log("Starting scan... (30 second timeout)");

      // Start scan - it will timeout after 30 seconds
      const foundDevices = await ThermalBleModule.scanDevices();
      console.log("Scan completed, devices:", foundDevices);
      setDevices(foundDevices);
    } catch (error) {
      console.error("Scan error:", error);
    } finally {
      setScanning(false);
      setScanStartTime(0);
    }
  };

  const handleConnect = async (device: { address: string; name: string }) => {
    console.log(device);
    await ThermalBleModule.connect(device.address);

    console.log("connected");
  };

  const stopScan = async () => {
    try {
      await ThermalBleModule.stopScan();
      console.log("Scan stopped");
      setScanning(false);
    } catch (error) {
      console.error("Stop scan error:", error);
    }
  };

  const testPrint = async () => {
    try {
      await ThermalPrinter.printText("Hello World!");
      await ThermalPrinter.printText("This is a test print");
      await ThermalPrinter.printLine();
      await ThermalPrinter.setBold(true);
      await ThermalPrinter.printText("Bold text");
      await ThermalPrinter.setBold(false);
      await ThermalPrinter.feed(2);
      console.log("Print completed");
    } catch (error) {
      console.error("Print error:", error);
    }
  };

  const testColumnPrint = async () => {
    try {
      // Set printer width for 58mm printer (32 characters)
      ThermalPrinter.setPrinterWidth(58);

      await ThermalPrinter.setAlignment(1); // Center
      await ThermalPrinter.printText("=== RECEIPT ===");
      await ThermalPrinter.setAlignment(0); // Left
      await ThermalPrinter.printLine();

      // Print items using two-column layout
      await ThermalPrinter.printTwoColumns("Coffee x2", "$5.00");
      await ThermalPrinter.printTwoColumns("Sandwich", "$8.50");
      await ThermalPrinter.printTwoColumns("Tax", "$1.35");

      await ThermalPrinter.printText("--------------------------------");

      await ThermalPrinter.setBold(true);
      await ThermalPrinter.printTwoColumns("TOTAL", "$14.85");
      await ThermalPrinter.setBold(false);

      await ThermalPrinter.feed(3);
      console.log("Column print completed");
    } catch (error) {
      console.error("Column print error:", error);
    }
  };

  const testQRCodePrint = async () => {
    try {
      await ThermalPrinter.setAlignment(1); // Center
      await ThermalPrinter.printText("=== QR CODE TEST ===");
      await ThermalPrinter.setAlignment(0); // Left
      await ThermalPrinter.printLine();

      // Print QR code with website URL (automatically sized and centered)
      await ThermalPrinter.printQRCode("https://www.example.com");

      await ThermalPrinter.printImage(base);

      await ThermalPrinter.printImage(pika);

      await ThermalPrinter.printLine();
      await ThermalPrinter.setAlignment(1); // Center
      await ThermalPrinter.printText("Scan to visit website");
      await ThermalPrinter.setAlignment(0); // Left

      await ThermalPrinter.feed(2);
      console.log("QR code print completed");
    } catch (error) {
      console.error("QR code print error:", error);
    }
  };

  return (
    <SafeAreaView style={styles.container}>
      <ScrollView style={styles.container}>
        <Text style={styles.header}>Thermal Printer BLE Test</Text>

        <Group name="Bluetooth Scanning">
          <Button
            title={scanning ? "Scanning... (30s timeout)" : "Start Scan"}
            onPress={startScan}
            disabled={scanning}
          />
          {scanning && (
            <>
              <Button title="Stop Scan Early" onPress={stopScan} />
              <Text>Scanning will auto-stop after 30 seconds</Text>
            </>
          )}

          {devices.length > 0 && (
            <View>
              <Text style={styles.groupHeader}>Found Devices:</Text>
              {devices.map((device, index) => (
                <TouchableOpacity
                  onPress={() => handleConnect(device)}
                  key={index}
                >
                  <Text>
                    {device.name || "Unknown"} - {device.address}
                  </Text>
                </TouchableOpacity>
              ))}
            </View>
          )}
        </Group>

        <Group name="Print Test">
          <Button title="Print Test" onPress={testPrint} />
          <Button title="Print Receipt (Columns)" onPress={testColumnPrint} />
          <Button title="Print QR Code" onPress={testQRCodePrint} />
        </Group>
      </ScrollView>
    </SafeAreaView>
  );
}

function Group(props: { name: string; children: React.ReactNode }) {
  return (
    <View style={styles.group}>
      <Text style={styles.groupHeader}>{props.name}</Text>
      {props.children}
    </View>
  );
}

const styles = {
  header: {
    fontSize: 30,
    margin: 20,
  },
  groupHeader: {
    fontSize: 20,
    marginBottom: 20,
  },
  group: {
    margin: 20,
    backgroundColor: "#fff",
    borderRadius: 10,
    padding: 20,
  },
  container: {
    flex: 1,
    backgroundColor: "#eee",
  },
  view: {
    flex: 1,
    height: 200,
  },
};
