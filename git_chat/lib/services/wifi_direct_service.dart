import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// Flutter wrapper for native Android Wi-Fi Direct (WifiP2pManager)
class WifiDirectService {
  static const _channel = MethodChannel('com.gitchat/wifi_direct');

  /// Caller creates a Wi-Fi Direct group — becomes group owner at 192.168.49.1
  static Future<Map<String, dynamic>> createGroup() async {
    try {
      final result = await _channel.invokeMethod('createGroup');
      debugPrint('[WIFID] createGroup result: $result');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      debugPrint('[WIFID] createGroup error: $e');
      return {
        'groupFormed': false,
        'isGroupOwner': false,
        'groupOwnerAddress': '',
      };
    }
  }

  /// Callee discovers and connects to a nearby Wi-Fi Direct group
  static Future<Map<String, dynamic>> discoverAndConnect() async {
    try {
      final result = await _channel.invokeMethod('discoverAndConnect');
      debugPrint('[WIFID] discoverAndConnect result: $result');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      debugPrint('[WIFID] discoverAndConnect error: $e');
      return {
        'groupFormed': false,
        'isGroupOwner': false,
        'groupOwnerAddress': '',
      };
    }
  }

  /// Get current connection info (IPs)
  static Future<Map<String, dynamic>> getConnectionInfo() async {
    try {
      final result = await _channel.invokeMethod('getConnectionInfo');
      debugPrint('[WIFID] getConnectionInfo result: $result');
      return Map<String, dynamic>.from(result as Map);
    } catch (e) {
      debugPrint('[WIFID] getConnectionInfo error: $e');
      return {
        'groupFormed': false,
        'isGroupOwner': false,
        'groupOwnerAddress': '',
      };
    }
  }

  /// Remove the Wi-Fi Direct group (cleanup after call)
  static Future<void> removeGroup() async {
    try {
      await _channel.invokeMethod('removeGroup');
      debugPrint('[WIFID] Group removed');
    } catch (e) {
      debugPrint('[WIFID] removeGroup error: $e');
    }
  }

  /// Bind the entire process to the Wi-Fi Direct (p2p0) network.
  /// This forces WebRTC ICE to gather candidates on the p2p0 interface
  /// instead of only loopback 127.0.0.1.
  static Future<bool> bindToP2pNetwork() async {
    try {
      final result = await _channel.invokeMethod('bindToP2pNetwork');
      debugPrint('[WIFID] bindToP2pNetwork: $result');
      return result == true;
    } catch (e) {
      debugPrint('[WIFID] bindToP2pNetwork error: $e');
      return false;
    }
  }

  /// Unbind the process from the p2p network (restore default routing)
  static Future<void> unbindNetwork() async {
    try {
      await _channel.invokeMethod('unbindNetwork');
      debugPrint('[WIFID] Network unbound');
    } catch (e) {
      debugPrint('[WIFID] unbindNetwork error: $e');
    }
  }
}
