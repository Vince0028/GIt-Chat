import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

class PermissionService {
  /// Request all necessary permissions for Nearby Connections (Mesh Networking).
  /// Returns true only if all critical permissions are granted.
  static Future<bool> requestPermissions() async {
    if (!Platform.isAndroid) return true;

    // Request all needed permissions at once
    final statuses = await [
      Permission.location, // Required for Android < 12 and Wi-Fi Direct
      Permission.bluetoothScan, // Required for Android 12+
      Permission.bluetoothConnect, // Required for Android 12+
      Permission.bluetoothAdvertise, // Required for Android 12+
      Permission.nearbyWifiDevices, // Required for Android 13+
      Permission.camera, // Required for video calls
      Permission.microphone, // Required for audio/video calls
    ].request();

    // Check location service is enabled (not just the permission — the GPS toggle)
    final locationEnabled = await Permission.location.serviceStatus.isEnabled;
    if (!locationEnabled) {
      debugPrint(
        '[PERMS] ⚠️ Location services are OFF — BLE scanning will NOT work!',
      );
    }

    // Determine minimum required set: location OR nearbyWifi + bluetooth
    final locationGranted = statuses[Permission.location]?.isGranted ?? false;
    final btScanGranted =
        statuses[Permission.bluetoothScan]?.isGranted ?? false;
    final btConnectGranted =
        statuses[Permission.bluetoothConnect]?.isGranted ?? false;
    final btAdvertiseGranted =
        statuses[Permission.bluetoothAdvertise]?.isGranted ?? false;

    final bluetoothOk = btScanGranted && btConnectGranted && btAdvertiseGranted;

    if (!bluetoothOk) {
      debugPrint('[PERMS] ❌ Bluetooth permissions denied — cannot start mesh.');
      return false;
    }
    if (!locationGranted) {
      debugPrint(
        '[PERMS] ❌ Location permission denied — discovery may fail on Android < 12.',
      );
      return false;
    }
    if (!locationEnabled) {
      debugPrint('[PERMS] ❌ Location service disabled — discovery will fail.');
      return false;
    }

    debugPrint('[PERMS] ✅ All permissions granted.');
    return true;
  }

  /// Returns a human-readable list of what is missing (for UI display)
  static Future<List<String>> getMissingPermissions() async {
    if (!Platform.isAndroid) return [];
    final missing = <String>[];

    if (!await Permission.location.isGranted) missing.add('Location');
    if (!await Permission.bluetoothScan.isGranted)
      missing.add('Bluetooth Scan');
    if (!await Permission.bluetoothConnect.isGranted)
      missing.add('Bluetooth Connect');
    if (!await Permission.bluetoothAdvertise.isGranted)
      missing.add('Bluetooth Advertise');

    final locationEnabled = await Permission.location.serviceStatus.isEnabled;
    if (!locationEnabled) missing.add('Location Services (GPS toggle)');

    return missing;
  }
}
