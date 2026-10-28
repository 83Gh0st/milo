import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Photo prep shared by Understand and Chat's "show Milo": bakes
/// orientation, caps the long side at 1600 px, WIPES EXIF (including GPS),
/// and re-encodes JPEG under ~1.9 MB. Pure function: callers run it in
/// `compute()` and delete the original file (with EXIF) right after.
Uint8List preparePhoto(Uint8List bytes) {
  var im = img.decodeImage(bytes);
  if (im == null) return bytes;
  im = img.bakeOrientation(im);
  if (im.width > 1600 || im.height > 1600) { im = im.width >= im.height ? img.copyResize(im, width: 1600) : img.copyResize(im, height: 1600); }
  im.exif = img.ExifData();
  var q = 80;
  var out = img.encodeJpg(im, quality: q);
  while (out.length > 1900000 && q > 30) { q -= 15; out = img.encodeJpg(im, quality: q); }
  return Uint8List.fromList(out);
}
