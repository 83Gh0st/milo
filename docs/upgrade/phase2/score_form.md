# Milo expression blind test — score form (Phase 2 acceptance)

Target: ≥ 80% correct on the 8 core emotions, and **zero** "angry" labels for
happy, curious, thinking and encouraging. 5 people, each shown the 8 faces.

## How to run it

1. Open Milo Lab (long-press the version in More → About).
2. Set renderer v2 + the picked look.
3. Pose each emotion below (tap the chip), screenshot the buddy preview at the
   same size, crop to the face. `expression_sheet_A.png` shows the format
   (it holds the 5 PIL reference expressions, not the shipped renderer).
4. Show the 8 crops in random order. Ask: "How is Milo feeling?" Record the
   exact word. Never prompt with the emotion list.

## Score sheet

| # | Shown | P1 | P2 | P3 | P4 | P5 | Correct /5 |
|---|---|---|---|---|---|---|---|
| 1 | happy | | | | | | /5 |
| 2 | excited | | | | | | /5 |
| 3 | curious | | | | | | /5 |
| 4 | thinking | | | | | | /5 |
| 5 | encouraging | | | | | | /5 |
| 6 | proud | | | | | | /5 |
| 7 | concerned | | | | | | /5 |
| 8 | sleepy | | | | | | /5 |

"Angry" labels for happy/curious/thinking/encouraging: ___ (must be 0).

Result: ___ /40 correct (target ≥ 32).
