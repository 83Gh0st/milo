// Milo's twelve expressions (doc 5.3). These are Milo's poses, NOT a reading of the user.
class Face {
  final double eye, browY, browA, browAsym, smile, mouth, width, blush, perk, valence, arousal;
  final String fx;
  final bool happyEyes, tongue;
  const Face({required this.eye, this.browY=0, this.browA=0, this.browAsym=0, this.smile=.3, this.mouth=0, this.width=13, this.blush=.1,
      this.perk=0, this.valence=0, this.arousal=.2, this.fx='', this.happyEyes=false, this.tongue=false});
  static double _l(double a, double b, double t) => a + (b - a) * t;
  /// Numbers blend; discrete traits (fx, happy eyes, tongue) come from [d].
  static Face lerp(Face a, Face b, double t, Face d) => Face(
      eye:_l(a.eye,b.eye,t), browY:_l(a.browY,b.browY,t), browA:_l(a.browA,b.browA,t), browAsym:_l(a.browAsym,b.browAsym,t), smile:_l(a.smile,b.smile,t),
      mouth:_l(a.mouth,b.mouth,t), width:_l(a.width,b.width,t), blush:_l(a.blush,b.blush,t), perk:_l(a.perk,b.perk,t),
      valence:_l(a.valence,b.valence,t), arousal:_l(a.arousal,b.arousal,t), fx:d.fx, happyEyes:d.happyEyes, tongue:d.tongue);
}

const faces = <String, Face>{
  'calm': Face(eye:.8, smile:.25, arousal:.1),
  'happy': Face(eye:1, browY:-2, browA:.15, smile:1, mouth:.15, width:16, blush:.45, perk:.4, valence:.7, arousal:.5),
  'excited': Face(eye:1.2, browY:-8, smile:1, mouth:.7, width:19, blush:.6, perk:1, valence:.9, arousal:.9, fx:'spark'),
  'curious': Face(eye:1.1, browY:-5, browA:.1, browAsym:.6, smile:.3, width:10, blush:.15, perk:.6, valence:.4, arousal:.5),
  'thinking': Face(eye:.8, browY:-2, browA:.05, smile:0, width:9, perk:.2, arousal:.4, fx:'dots'),
  'listening': Face(eye:1.25, browY:-6, smile:.1, width:10, perk:.7, arousal:.5, fx:'arcs'),
  'encouraging': Face(eye:.9, browY:-3, browA:.3, smile:.9, mouth:.1, width:15, blush:.5, perk:.5, valence:.6, arousal:.4),
  'proud': Face(eye:.9, browY:-5, smile:1, mouth:.1, width:17, blush:.5, perk:.8, valence:.8, arousal:.4, happyEyes:true, fx:'spark'),
  'concerned': Face(eye:.95, browY:-4, browA:.8, smile:-.5, width:10, perk:-.2, valence:-.4, arousal:.15),
  'sleepy': Face(eye:.3, browY:2, smile:.1, width:10, blush:.2, perk:-.7, arousal:0, fx:'zzz'),
  'playful': Face(eye:1, browY:-4, browA:.1, smile:1, mouth:.5, width:18, blush:.6, perk:.8, valence:.7, arousal:.8, tongue:true),
  'surprised': Face(eye:1.35, browY:-10, smile:0, mouth:.9, width:9, blush:.1, perk:1, arousal:.9),
};
