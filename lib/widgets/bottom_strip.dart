import 'package:flutter/material.dart';

/// The colour of the strip the app paints under the system navigation bar (see the builder in
/// main.dart). White everywhere, except while the splash is up: then it matches the splash
/// background, so the light splash does not end in a white band at the bottom.
final ValueNotifier<Color> bottomStripColor = ValueNotifier<Color>(Colors.white);
