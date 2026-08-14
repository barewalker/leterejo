#!/bin/sh
# Does the kitty graphics protocol survive the way to this terminal?
#
# Neither Neovim nor any plugin is involved: this writes the escape sequences
# straight to the tty. Run it wherever an image failed to appear and compare
# with the same run in the bare terminal. Whatever differs is the layer at
# fault.
#
#   ./kitty-graphics-probe.sh [some.png]
#
# Two placements are tried, because a multiplexer can carry one and not the
# other:
#
#   1. direct     the image is drawn where the cursor is (a=T)
#   2. placeholder  a character is written into the text and the terminal
#                   paints the image over it (U=1). This is what an editor
#                   needs, since it has to keep its own layout, and it is much
#                   the harder of the two to implement.
#
# The protocol takes PNG only for file transmission, which is why a PNG is
# asked for.
set -eu

PNG=${1:-/usr/share/pixmaps/htop.png}
[ -r "$PNG" ] || { echo "cannot read: $PNG" >&2; exit 1; }

case "$PNG" in
  *.png|*.PNG) ;;
  *) echo "not a .png; the protocol will refuse it: $PNG" >&2; exit 1 ;;
esac

B64=$(printf %s "$PNG" | base64 | tr -d '\n')

echo "terminal: TERM=$TERM  ${KITTY_WINDOW_ID:+KITTY_WINDOW_ID=$KITTY_WINDOW_ID }${HERDR_ENV:+HERDR=1 }${TTYSKK_ACTIVE:+TTYSKK=1}"
echo "file:     $PNG"
echo

echo "1. direct placement (a=T) — an image should appear below:"
printf '\033_Ga=T,f=100,t=f,c=20,r=6,q=2;%s\033\\' "$B64"
printf '\n\n'

echo "2. unicode placeholder (U=1) — an image should appear below:"
# Transmit under an id, then write the placeholder cells. The id is carried in
# the cell's foreground colour — that is how the terminal knows which image a
# cell belongs to — so the id and the colour have to be the same number. 155 is
# used for both.
printf '\033_Ga=t,f=100,t=f,i=155,q=2;%s\033\\' "$B64"
printf '\033_Ga=p,i=155,U=1,c=20,r=6,q=2\033\\'
# 0x10EEEE is the placeholder; the combining marks say which row and column of
# the image each cell holds. printf in a POSIX shell cannot spell a codepoint
# above U+FFFF, so the cells are written out by python.
python3 - <<'CELLS'
D = ("0305 030D 030E 0310 0312 033D 033E 033F 0346 034A "
     "034B 034C 0350 0351 0352 0357 035B 0363 0364 0365").split()
out = ["\033[38;5;155m"]
for r in range(6):
    out.append("".join("\U0010EEEE" + chr(int(D[r], 16)) + chr(int(D[c], 16))
                       for c in range(20)) + "\n")
out.append("\033[0m")
print("".join(out))
CELLS

echo
echo "Neither appeared: the protocol is not reaching this terminal."
echo "Only the first: the layer in between carries images but not placeholders,"
echo "which is the one an editor needs."
