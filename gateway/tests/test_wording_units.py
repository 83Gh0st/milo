"""Plan 7.5 acceptance: 50 wording-help cases, zero invented facts, feelings
or consent. Stdlib-only so it runs anywhere (same command as the other unit
files). Each expectation was checked against the guard's three rules:
digit-words, mid-sentence capitals, and the feeling/consent sets."""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]))

from app.safety import no_new_content

PASS = [
    (["I", "want", "water"], "Can I have water, please?"),
    (["help", "bathroom"], "I need the bathroom, please help me"),
    (["more", "food"], "I want more food, please"),
    (["stop", "no"], "No, please stop"),
    (["I", "hurt"], "I am hurt, I need help"),
    (["I", "want", "go", "home"], "I want to go home now"),
    (["tired", "sleep"], "I am tired and want to sleep"),
    (["like", "play"], "I like to play"),
    (["not", "like"], "I do not like this"),
    (["water", "please"], "Water, please"),
    (["bathroom", "now"], "I need the bathroom now"),
    (["hungry", "food"], "I am hungry and want food"),
    (["sad", "help"], "I feel sad, please help me"),
    (["yes", "water"], "Yes, water please"),
    (["happy", "play"], "I am happy and want to play"),
    (["doctor", "hurt"], "The doctor, my leg is hurt"),
    (["school", "bus"], "Where is the school bus"),
    (["thank", "you"], "Thank you"),
    (["more", "time"], "I need more time, please"),
    (["all", "done", "finished"], "I am all done and finished"),
    (["look", "dog"], "Look at the dog"),
    (["go", "park"], "I want to go to the park"),
    (["read", "book"], "Please read me the book"),
    (["music", "loud"], "The music is too loud"),
    (["cold", "blanket"], "I feel cold under this blanket"),
]

FAIL = [
    (["I", "want", "water"], "Maria is happy and wants water 3 times"),
    (["help"], "I promise I will be good"),
    (["water"], "Yes"),
    (["play"], "I agree to share"),
    (["food"], "I want pizza 2 times"),
    (["bathroom"], "Meet me at Room 5"),
    (["hurt"], "The nurse said Sam pushed me"),
    (["tired"], "I am very sad today"),
    (["go", "home"], "I love going home"),
    (["stop"], "No, I hate this game"),
    (["more"], "I am excited for cake"),
    (["dark"], "I am scared of the dark"),
    (["spill"], "I am sorry about the spill"),
    (["please"], "Yes please"),
    (["outside"], "Mom said I can go outside"),
    (["doctor"], "Call Doctor Rao now"),
    (["school"], "I go to Lincoln School"),
    (["water"], "I drank 500 ml of water"),
    (["birthday", "party"], "The party is on Friday"),
    (["help", "me"], "Help me, I am worried"),
    (["eat", "lunch"], "I allow you to sit here"),
    (["friend"], "My friend agrees with me"),
    (["medicine"], "Take 2 pills"),
    (["dog"], "The angry dog barked"),
    (["book"], "Harry Potter is the best book"),
]


def test_wording_help_fifty_cases():
    assert len(PASS) + len(FAIL) == 50
    for strip, cand in PASS:
        assert no_new_content(strip, cand), ("PASS-case rejected", strip, cand)
    for strip, cand in FAIL:
        assert not no_new_content(strip, cand), ("FAIL-case accepted", strip, cand)
