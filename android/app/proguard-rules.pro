# ML Kit text recognition: the plugin references script-specific recognizer
# options (Chinese/Devanagari/Japanese/Korean) that ship in separate
# artifacts Milo does not bundle. Latin recognition (bundled) is unaffected;
# without these rules R8 full mode fails the release build on missing classes.
-dontwarn com.google.mlkit.vision.text.**
