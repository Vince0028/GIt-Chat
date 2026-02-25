import 'dart:io';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:google_fonts/google_fonts.dart';
import '../theme/app_theme.dart';

class PermissionService {
  /// Request all Bluetooth-related permissions for Android
  static Future<bool> requestBluetoothPermissions() async {
    if (!Platform.isAndroid) return true;

    final statuses = await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.bluetoothAdvertise,
      Permission.location,
    ].request();

    return statuses.values.every((s) => s == PermissionStatus.granted);
  }

  /// Check if Bluetooth is turned on, prompt user if not
  static Future<bool> ensureBluetoothOn(BuildContext context) async {
    final adapterState = await FlutterBluePlus.adapterState.first;

    if (adapterState == BluetoothAdapterState.on) {
      return true;
    }

    // On Android, try to turn on Bluetooth
    if (Platform.isAndroid) {
      try {
        await FlutterBluePlus.turnOn();
        return true;
      } catch (_) {
        // User denied
      }
    }

    // Show manual enable dialog
    if (context.mounted) {
      await showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          backgroundColor: AppTheme.bgCard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: const BorderSide(color: AppTheme.border),
          ),
          title: Row(
            children: [
              const Icon(Icons.bluetooth_disabled, color: AppTheme.orange),
              const SizedBox(width: 8),
              Text(
                'Bluetooth Off',
                style: GoogleFonts.firaCode(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                ),
              ),
            ],
          ),
          content: Text(
            'BitChat needs Bluetooth to discover\nnearby peers and relay messages.\n\nPlease enable Bluetooth in Settings.',
            style: GoogleFonts.firaCode(
              color: AppTheme.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: Text(
                'OK',
                style: GoogleFonts.firaCode(color: AppTheme.green),
              ),
            ),
          ],
        ),
      );
    }

    return false;
  }

  /// Check all permissions at once
  static Future<bool> checkAndRequestAll(BuildContext context) async {
    final blePerms = await requestBluetoothPermissions();
    if (!blePerms) return false;

    if (context.mounted) {
      final bleOn = await ensureBluetoothOn(context);
      return bleOn;
    }

    return false;
  }
}
