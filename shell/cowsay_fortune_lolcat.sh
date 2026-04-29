#!/bin/bash

## Check if the necessary commands are available
if command -v fortune >/dev/null 2>&1 &&
  command -v cowsay >/dev/null 2>&1 &&
  command -v lolcat >/dev/null 2>&1; then

  ## Standard cowsay character (medium 5 lines)
  fortune | cowsay | lolcat

  ## Calf cowsay character (small 4 lines)
  #fortune | cowsay -f small.cow | lolcat

  ## Ghostbusters cowsay character (large over 10 lines)
  #fortune | cowsay -f ghostbusters.cow | lolcat

  ## Satanic Goat cowsay character (medium 7 lines)
  #fortune | cowsay -f satanic.cow | lolcat

  ## Moose cowsay character (medium 7 lines)
  #fortune | cowsay -f moose.cow | lolcat

  ## Dinosaur cowsay character (large over 10 lines)
  #fortune | cowsay -f stegosaurus.cow | lolcat

  ## Turtle cowsay character (large over 10 lines)
  #fortune | cowsay -f turtle.cow | lolcat

  ## Linux Tux cowsay character (medium 9 lines)
  #fortune | cowsay -f tux.cow | lolcat

  ## Random cowsay character (Improved: Randomly choose a character)
  #fortune | cowsay -f "$(ls /opt/homebrew/Cellar/cowsay/*/share/cows/*.cow | sort -R | head -1)" | lolcat

else
  echo "Required commands (fortune, cowsay, lolcat) are not installed or not in your PATH."
fi
