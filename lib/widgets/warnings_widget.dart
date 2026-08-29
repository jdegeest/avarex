
import 'dart:core';
import 'package:avaremp/constants.dart';
import 'package:avaremp/io/gps.dart' show GpsState;
import 'package:avaremp/storage.dart' show Storage;
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:flutter_material_design_icons/flutter_material_design_icons.dart';

class WarningsButtonWidget extends StatefulWidget {
  const WarningsButtonWidget({super.key, required this.warning});

  final bool warning;

  @override
  State<StatefulWidget> createState() => WarningsButtonWidgetState();
}

// a button to show if there is an issue
class WarningsButtonWidgetState extends State<WarningsButtonWidget> {


  @override
  Widget build(BuildContext context) {

    if(widget.warning) {
      return IconButton(
        icon: CircleAvatar(backgroundColor: Colors.black, radius: 20, child: Icon(MdiIcons.alertCircle, color: Colors.red, size: 40)),
          onPressed: () {
            Scaffold.of(context).openEndDrawer();
          },
        );
    }

    return(Container());
  }
}

class WarningsWidget extends StatefulWidget {
  const WarningsWidget({super.key, required this.gpsNotPermitted,
    required this.gpsDisabled, required this.chartsMissing, required this.dataExpired, required this.signed, required this.gpsNoLock, required this.exceptions});

  final bool gpsNotPermitted;
  final bool gpsDisabled;
  final bool chartsMissing;
  final bool dataExpired;
  final bool signed;
  final bool gpsNoLock;
  final List<String> exceptions;

  @override
  State<StatefulWidget> createState() => WarningsWidgetState();
}

class WarningsWidgetState extends State<WarningsWidget> {

  @override
  Widget build(BuildContext context) {

    List<ListTile> list = [
      ListTile(
        title: const Text("Issues", style: TextStyle(fontWeight: FontWeight.w900)),
        subtitle: const Text("Tapping on the issue may help you resolve it."),
        leading: Icon(MdiIcons.alertCircle, color: Colors.red,), dense: false,)];

    // One tile driven by Storage().gpsState, so the drawer, the SRC tile and
    // the diagnostics screen can never disagree about what is wrong. The old
    // three booleans overlapped: "permission denied" also fired when the
    // platform had no provider, and "no lock" fired even when there was no
    // receiver to get a lock with.
    final GpsState gpsState = Storage().gpsState;
    if (gpsState != GpsState.internalFix && gpsState != GpsState.externalFix) {
      const Map<GpsState, (String, IconData)> presentation = {
        GpsState.noProvider:              ("No GPS on this computer", Icons.gps_off_sharp),
        GpsState.internalPermissionDenied:("Location access denied", Icons.gpp_good_sharp),
        GpsState.internalServiceOff:      ("Location services off", Icons.gps_off_sharp),
        GpsState.internalSearching:       ("GPS has no fix yet", Icons.gps_not_fixed),
        GpsState.externalNoOwnship:       ("Receiver has no GPS fix", Icons.satellite_alt),
        GpsState.externalNoData:          ("No receiver data", Icons.wifi_off),
      };
      final (String title, IconData icon) =
          presentation[gpsState] ?? ("GPS", Icons.gps_not_fixed);
      // Only offer a settings jump where one actually exists and would help.
      final bool actionable = !Constants.isDesktop &&
          (gpsState == GpsState.internalPermissionDenied ||
           gpsState == GpsState.internalServiceOff);
      list.add(ListTile(
          title: Text(title),
          leading: Icon(icon),
          subtitle: Text(Storage().gpsStateMessage),
          dense: true,
          onTap: !actionable ? null : () {
            try {
              if (gpsState == GpsState.internalPermissionDenied) {
                Geolocator.openAppSettings();
              }
              else {
                Geolocator.openLocationSettings();
              }
            }
            catch(e) {
              Storage().setException("Error opening settings: $e");
            }
            Scaffold.of(context).closeEndDrawer();
          }));
    }

    String dataAvailableMessage = !widget.chartsMissing ? "" :
    "Critical data is missing, please download the databases and some charts using the Download menu.";
    if(dataAvailableMessage.isNotEmpty) {
      list.add(ListTile(title: const Text("Data"),
          leading: const Icon(Icons.download),
          subtitle: Text(dataAvailableMessage),
          dense: true,
          onTap: () {Navigator.pushNamed(context, '/download'); Scaffold.of(context).closeEndDrawer();}));
    }

    String dataCurrentMessage = !widget.dataExpired ? "" :
    "Some or all of your data has expired. Tap this text or use the Download menu to Update.";
    if(dataCurrentMessage.isNotEmpty) {
      list.add(ListTile(title: const Text("Update"),
          leading: const Icon(Icons.update),
          subtitle: Text(dataCurrentMessage),
          dense: true,
          onTap: () {Navigator.pushNamed(context, '/download'); Scaffold.of(context).closeEndDrawer();}));
    }

    String signMessage = widget.signed ? "" :
    "You must sign the Terms of Use to use this software.";
    if(signMessage.isNotEmpty) {
      list.add(ListTile(title: const Text("Sign Terms of Use"),
          leading: const Icon(Icons.verified_user_outlined),
          subtitle: Text(signMessage),
          dense: true,
          onTap: () {Navigator.pushNamed(context, '/terms'); Scaffold.of(context).closeEndDrawer();}));
    }

    for(String exception in widget.exceptions) {
      list.add(ListTile(title: const Text("Notice"),
          leading: const Icon(Icons.message),
          subtitle: Text(exception),
          dense: true,
          onTap: () {widget.exceptions.remove(exception); Navigator.pop(context);}));
    }

    return Drawer(
        child: ListView(children: list,
        )
    );
  }

}