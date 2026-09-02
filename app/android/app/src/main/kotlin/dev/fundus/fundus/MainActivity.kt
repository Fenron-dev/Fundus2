package dev.fundus.fundus

import io.flutter.embedding.android.FlutterActivity

/**
 * The plain activity.
 *
 * The previous client's activity carried method channels for direct storage
 * access, opening files in other apps and rendering PDF pages, and extended
 * audio_service's activity for background playback. None of that has been
 * rebuilt yet, and an activity referencing plugins the app no longer depends
 * on does not compile. The old file is kept verbatim under
 * legacy/android/MainActivity.kt.reference; each channel comes back with the
 * feature that needs it.
 */
class MainActivity : FlutterActivity()
